#!/bin/sh
# shellcheck disable=SC2164,SC2319,SC2103,SC1090,SC1091,SC2181,SC2217,SC2034,SC3044,SC2154,SC2088
#   cd failing, inspecting $? after it, and feeding its [y/N] prompt via stdin
#   are exactly what this suite tests. SC2154: _bcd_dash_mode is set by the
#   sourced bettercd.sh. SC2088: the ~ in a home-rel expectation is a literal
#   string to compare against, not a path meant to expand.
# bettercd test suite — pure POSIX sh, runs under bash and zsh.
# Usage: BETTERCD_SH=/path/to/bettercd.sh <shell> tests/suite.sh

BETTERCD_SH="${BETTERCD_SH:-$(dirname "$0")/../bettercd.sh}"
case "$BETTERCD_SH" in /*) ;; *) BETTERCD_SH="$PWD/$BETTERCD_SH" ;; esac

TMP="$(mktemp -d)" || exit 1
HOME="$TMP/home"; export HOME
XDG_CONFIG_HOME="$HOME/.config"; export XDG_CONFIG_HOME  # CI runners set this globally
mkdir -p "$HOME"
unset CDPATH
cd "$TMP" || exit 1

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }
check() { # $1 desc, $2 cond result (0=ok)
    if [ "$2" -eq 0 ]; then ok; else bad "$1"; fi
}

. "$BETTERCD_SH"

# 1. passthrough: existing dir
mkdir real
cd real
[ "$PWD" = "$TMP/real" ]; check "cd into existing dir" $?

# 2. cd - passthrough
cd - >/dev/null 2>&1
[ "$PWD" = "$TMP" ]; check "cd - returns" $?

# 3. cd no-arg goes home
cd
[ "$PWD" = "$HOME" ]; check "cd no-arg goes to HOME" $?
cd "$TMP"

# 4. auto-create single dir under cwd + hint mentions undo
cd newdir 2>"$TMP/.err"
[ "$PWD" = "$TMP/newdir" ] && [ -d "$TMP/newdir" ]; check "auto-create single dir" $?
grep -q "bettercd undo" "$TMP/.err"; check "hint shows undo" $?

# 5. undo returns + removes
bettercd undo 2>/dev/null
[ "$PWD" = "$TMP" ] && [ ! -d "$TMP/newdir" ]; check "undo removes created dir and returns" $?

# 5b. undo-cd alias (what the interactive create line suggests)
cd undotest 2>/dev/null
undo-cd 2>/dev/null
[ "$PWD" = "$TMP" ] && [ ! -d "$TMP/undotest" ]; check "undo-cd reverts create" $?

# 6. auto-create nested chain
cd a/b/c 2>/dev/null
[ "$PWD" = "$TMP/a/b/c" ]; check "auto-create nested chain" $?
bettercd undo 2>/dev/null
[ "$PWD" = "$TMP" ] && [ ! -d "$TMP/a" ]; check "undo removes whole created chain" $?

# 7. undo keeps non-empty dirs (rmdir-only safety)
cd x/y 2>/dev/null
touch keepme
bettercd undo 2>/dev/null
[ "$PWD" = "$TMP" ] && [ -f "$TMP/x/y/keepme" ]; check "undo keeps dirs with content" $?
rm -rf "$TMP/x"

# 8. ".." escaping cwd is NOT treated as under-cwd (no silent create)
mkdir -p sub && cd sub
cd foo/../../zzz 2>/dev/null
rc=$?
[ $rc -ne 0 ] && [ ! -d "$TMP/zzz" ] && [ "$PWD" = "$TMP/sub" ]
check "dot-dot escape is not auto-created" $?

# 9. out-of-base: second identical attempt + y creates (forced interactive)
_BETTERCD_FORCE_INTERACTIVE=1
target="$TMP/outside/deep"
cd "$target" 2>/dev/null   # first miss
cd "$target" 2>/dev/null <<'EOF'
y
EOF
[ "$PWD" = "$target" ] && [ -d "$target" ]; check "out-of-base double attempt + y creates" $?
bettercd undo 2>/dev/null
cd "$TMP/sub" 2>/dev/null

# 10. out-of-base: second attempt + n does NOT create
target2="$TMP/outside2/deep"
cd "$target2" 2>/dev/null
cd "$target2" 2>/dev/null <<'EOF'
n
EOF
[ $? -ne 0 ] && [ ! -d "$target2" ]; check "out-of-base double attempt + n refuses" $?
unset _BETTERCD_FORCE_INTERACTIVE

# 11. non-interactive: no prompt, no hang, no create on repeat
target3="$TMP/outside3/deep"
cd "$target3" 2>/dev/null
cd "$target3" 2>/dev/null </dev/null
[ $? -ne 0 ] && [ ! -d "$target3" ]; check "non-interactive repeat stays safe" $?

# 12. trailing slash creates
cd "$TMP" 2>/dev/null
cd tslash/ 2>/dev/null
[ "$PWD" = "$TMP/tslash" ]; check "trailing slash creates" $?
bettercd undo 2>/dev/null

# 13. spaces in names + raw undo one-liner round-trips
cd "$TMP"
cd "my dir/sub dir" 2>"$TMP/.err"
[ "$PWD" = "$TMP/my dir/sub dir" ]; check "auto-create with spaces" $?
oneliner="$(sed -n 's/.*(or: \(.*\))$/\1/p' "$TMP/.err")"
cd "$TMP"   # move parent shell out of the created dir first
( eval "$oneliner" ) 2>/dev/null
[ ! -d "$TMP/my dir" ]; check "raw undo one-liner works with spaces" $?

# 14. cd <file> goes to parent
mkdir -p fdir && touch fdir/somefile
cd fdir/somefile 2>/dev/null
[ "$PWD" = "$TMP/fdir" ]; check "cd file goes to parent dir" $?
cd "$TMP"

# 15. BETTERCD_AUTO_CREATE=0 disables creation
BETTERCD_AUTO_CREATE=0
cd nocreate 2>/dev/null
[ $? -ne 0 ] && [ ! -d "$TMP/nocreate" ]; check "BETTERCD_AUTO_CREATE=0 disables" $?
BETTERCD_AUTO_CREATE=1

# 16. CDPATH is still honored (no create shadowing)
mkdir -p "$TMP/cdp/proj2"
CDPATH="$TMP/cdp"; export CDPATH
cd "$TMP/sub"
cd proj2 >/dev/null 2>&1
[ "$PWD" = "$TMP/cdp/proj2" ] && [ ! -d "$TMP/sub/proj2" ]; check "CDPATH honored before create" $?
unset CDPATH
cd "$TMP"

# 17. flags passthrough
mkdir -p pdir
cd -P pdir 2>/dev/null
[ "$PWD" = "$TMP/pdir" ] || [ "$PWD" = "$(cd -P "$TMP" 2>/dev/null && pwd)/pdir" ]
check "cd -P flag passthrough" $?
cd "$TMP"

# 18. bettercd subcommands exit cleanly
bettercd version >/dev/null 2>&1; check "bettercd version" $?
bettercd status  >/dev/null 2>&1; check "bettercd status" $?
bettercd help    >/dev/null 2>&1; check "bettercd help" $?
bettercd undo    >/dev/null 2>&1   # drain stale undo state left by the subshell one-liner test
bettercd undo    >/dev/null 2>&1; [ $? -ne 0 ]; check "undo with nothing pending fails cleanly" $?
bettercd nosuch  >/dev/null 2>&1; [ $? -ne 0 ]; check "unknown subcommand fails" $?

# 19. backup writes a restorable snapshot
bettercd backup >/dev/null 2>&1; check "bettercd backup runs" $?
bdir="$(find "$HOME/.config/bettercd/backups" -name RESTORE.md 2>/dev/null | head -1)"
[ -n "$bdir" ]; check "backup contains RESTORE.md" $?

# 20. F1 typo guard ----------------------------------------------------------
cd "$TMP"
mkdir -p guard/src

# 20g. dist1 classifier sanity (add / remove / substitute / transpose)
__bettercd_dist1 sr src && __bettercd_dist1 teh the && ! __bettercd_dist1 abc xyz
check "typo guard: dist1 classifier" $?

# 20a. non-interactive: a typo still auto-creates (regression pin, CI safety)
cd "$TMP/guard"
cd sr 2>/dev/null </dev/null
[ "$PWD" = "$TMP/guard/sr" ] && [ -d "$TMP/guard/sr" ]
check "typo guard: non-interactive still auto-creates" $?
rmdir "$TMP/guard/sr" 2>/dev/null
cd "$TMP/guard"

# 20b. interactive + y → jump to the close match, no junk dir created
_BETTERCD_FORCE_INTERACTIVE=1
cd sr 2>/dev/null <<'EOF'
y
EOF
[ "$PWD" = "$TMP/guard/src" ] && [ ! -d "$TMP/guard/sr" ]
check "typo guard: interactive y jumps to match" $?
cd "$TMP/guard"

# 20c. interactive + c → create the typo dir as asked
cd sr 2>/dev/null <<'EOF'
c
EOF
[ "$PWD" = "$TMP/guard/sr" ] && [ -d "$TMP/guard/sr" ]
check "typo guard: interactive c creates target" $?
rmdir "$TMP/guard/sr" 2>/dev/null
cd "$TMP/guard"

# 20d. interactive + n → abort, nothing created
cd sr 2>/dev/null <<'EOF'
n
EOF
rc=$?
[ "$rc" -ne 0 ] && [ ! -d "$TMP/guard/sr" ] && [ "$PWD" = "$TMP/guard" ]
check "typo guard: interactive n aborts" $?

# 20e. BETTERCD_TYPO_GUARD=0 disables the guard (creates, no prompt)
BETTERCD_TYPO_GUARD=0
cd sr 2>/dev/null <<'EOF'
n
EOF
[ "$PWD" = "$TMP/guard/sr" ] && [ -d "$TMP/guard/sr" ]
check "typo guard: BETTERCD_TYPO_GUARD=0 skips" $?
unset BETTERCD_TYPO_GUARD
rmdir "$TMP/guard/sr" 2>/dev/null
cd "$TMP/guard"

# 20f. trailing slash skips the guard entirely (explicit create intent)
cd sr/ 2>/dev/null <<'EOF'
n
EOF
[ "$PWD" = "$TMP/guard/sr" ] && [ -d "$TMP/guard/sr" ]
check "typo guard: trailing slash skips guard" $?
unset _BETTERCD_FORCE_INTERACTIVE
cd "$TMP"
rm -rf "$TMP/guard"

# 20h. interactive typo guard with NO sibling dirs → clean fall-through create
#      (pins the zsh nomatch-on-empty-glob bug: guard must not block the create)
_BETTERCD_FORCE_INTERACTIVE=1
mkdir -p "$TMP/empty"; cd "$TMP/empty"
cd fresh 2>/dev/null </dev/null
[ "$PWD" = "$TMP/empty/fresh" ] && [ -d "$TMP/empty/fresh" ]
check "typo guard: empty parent falls through to create" $?
unset _BETTERCD_FORCE_INTERACTIVE
cd "$TMP"; rm -rf "$TMP/empty"

# 21. F2 editor-style paths ---------------------------------------------------
cd "$TMP"
mkdir -p eddir && touch eddir/file.py

# 21a. file:line → the file's parent directory
cd eddir/file.py:42 2>/dev/null
[ "$PWD" = "$TMP/eddir" ]; check "editor path: file:line → file's dir" $?
cd "$TMP"

# 21b. file:line:col → the file's parent directory
cd eddir/file.py:42:7 2>/dev/null
[ "$PWD" = "$TMP/eddir" ]; check "editor path: file:line:col → file's dir" $?
cd "$TMP"

# 21c. dir:line → enter the directory
cd eddir:7 2>/dev/null
[ "$PWD" = "$TMP/eddir" ]; check "editor path: dir:line → enters dir" $?
cd "$TMP"

# 21d. missing after strip → falls through to normal create (original arg)
cd nope.py:42 2>/dev/null
[ "$PWD" = "$TMP/nope.py:42" ] && [ -d "$TMP/nope.py:42" ]
check "editor path: missing-after-strip falls through to create" $?
bettercd undo 2>/dev/null
cd "$TMP"
rm -rf "$TMP/eddir"

# 22. F3 sparkle theming (non-tty: plain output, safe fallbacks, no crash) ----
cd "$TMP"
BETTERCD_SPARKLE_COLORS="1 2 3" BETTERCD_SPARKLE_GLYPHS="a b c" cd f3dir 2>"$TMP/.err"
[ "$PWD" = "$TMP/f3dir" ] && [ -d "$TMP/f3dir" ]
check "sparkle theming: custom env still creates (non-tty plain)" $?
grep -q "bettercd: created" "$TMP/.err"
check "sparkle theming: non-tty keeps plain create message" $?
bettercd undo 2>/dev/null
cd "$TMP"

BETTERCD_SPARKLE_COLORS="not numbers" cd f3bad 2>/dev/null
[ "$PWD" = "$TMP/f3bad" ] && [ -d "$TMP/f3bad" ]
check "sparkle theming: invalid colors safe" $?
bettercd undo 2>/dev/null
cd "$TMP"

[ "$(__bettercd_nth 'a b c' 0)" = a ] && [ "$(__bettercd_nth 'a b c' 4)" = b ]
check "sparkle theming: nth wraps frames" $?

# 23. cd-typo aliases (cd.. / cd...) — eval forces a fresh parse so the
# alias (defined after this file began parsing) is active; bash also needs
# expand_aliases in non-interactive shells
if [ -n "${BASH_VERSION-}" ]; then shopt -s expand_aliases 2>/dev/null; fi
if [ -n "${ZSH_VERSION-}${BASH_VERSION-}" ]; then
    mkdir -p "$TMP/cnf/a/b" && cd "$TMP/cnf/a/b"
    eval 'cd..' 2>/dev/null
    [ "$PWD" = "$TMP/cnf/a" ]; check "cd.. goes up one" $?
    cd "$TMP/cnf/a/b"
    eval 'cd...' 2>/dev/null
    [ "$PWD" = "$TMP/cnf" ]; check "cd... goes up two" $?
    cd "$TMP/cnf/a/b"
    eval 'cd....' 2>/dev/null
    [ "$PWD" = "$TMP" ]; check "cd.... goes up three" $?
    cd "$TMP"
fi

# 24. magic cd - state machine + CLI (non-tty: helper is pure, cd -/-- gated) -
cd "$TMP"
unset BETTERCD_MAGIC BETTERCD_MAGIC_WINDOW _BETTERCD_FORCE_INTERACTIVE

# NB: __bettercd_dash_mode sets $_bcd_dash_mode and mutates state IN THE CURRENT
# shell — call it directly, never via $(...) (a subshell would drop the state).

# default is OPT-IN now: without BETTERCD_MAGIC=1 every dash is classic
_BETTERCD_LAST_DASH=""; _BETTERCD_MAGIC_UNTIL=""
__bettercd_dash_mode 1000; d1="$_bcd_dash_mode"
__bettercd_dash_mode 1010; d2="$_bcd_dash_mode"
[ "$d1" = classic ] && [ "$d2" = classic ]; check "magic: default (unset) is always classic" $?
BETTERCD_MAGIC=1   # the state-machine tests below exercise the opt-in mode

# 24a. fresh state → first dash is classic
_BETTERCD_LAST_DASH=""; _BETTERCD_MAGIC_UNTIL=""
__bettercd_dash_mode 1000; [ "$_bcd_dash_mode" = classic ]; check "magic: first dash is classic" $?

# 24b. a second dash within 60s activates magic
__bettercd_dash_mode 1030; [ "$_bcd_dash_mode" = magic ]; check "magic: 2nd dash within 60s activates" $?

# 24c. magic persists while now < UNTIL (default 300s window)
__bettercd_dash_mode 1100; [ "$_bcd_dash_mode" = magic ]; check "magic: persists inside window" $?

# 24d. each magic hit refreshes UNTIL to now+window
[ "$_BETTERCD_MAGIC_UNTIL" = 1400 ]; check "magic: window refreshes on hit" $?

# 24e. lone dashes far apart stay classic
_BETTERCD_LAST_DASH=""; _BETTERCD_MAGIC_UNTIL=""
__bettercd_dash_mode 5000; r1="$_bcd_dash_mode"
__bettercd_dash_mode 5200; r2="$_bcd_dash_mode"
[ "$r1" = classic ] && [ "$r2" = classic ]; check "magic: lone dashes stay classic" $?

# 24f. BETTERCD_MAGIC=0 → always classic
BETTERCD_MAGIC=0; _BETTERCD_LAST_DASH=""; _BETTERCD_MAGIC_UNTIL=""
__bettercd_dash_mode 1000; c1="$_bcd_dash_mode"
__bettercd_dash_mode 1010; c2="$_bcd_dash_mode"
[ "$c1" = classic ] && [ "$c2" = classic ]; check "magic: BETTERCD_MAGIC=0 forces classic" $?
BETTERCD_MAGIC=1

# 24g. window override respected (600s)
BETTERCD_MAGIC_WINDOW=600; _BETTERCD_LAST_DASH=""; _BETTERCD_MAGIC_UNTIL=""
__bettercd_dash_mode 2000   # classic, arms LAST_DASH
__bettercd_dash_mode 2030   # magic → UNTIL = 2030+600
[ "$_BETTERCD_MAGIC_UNTIL" = 2630 ]; check "magic: window override respected" $?
unset BETTERCD_MAGIC_WINDOW BETTERCD_MAGIC; _BETTERCD_LAST_DASH=""; _BETTERCD_MAGIC_UNTIL=""

# 24h. CLI sets vars correctly + validates
bettercd magic off >/dev/null;      [ "$BETTERCD_MAGIC" = 0 ];        check "magic cmd: off sets var" $?
bettercd magic on  >/dev/null;      [ "$BETTERCD_MAGIC" = 1 ];        check "magic cmd: on sets var" $?
bettercd magic window 10 >/dev/null; [ "$BETTERCD_MAGIC_WINDOW" = 600 ]; check "magic cmd: window 10 → 600s" $?
bettercd magic status >/dev/null 2>&1;                                check "magic cmd: status runs" $?
bettercd magic window abc >/dev/null 2>&1; [ $? -ne 0 ];              check "magic cmd: window rejects non-numeric" $?
unset BETTERCD_MAGIC BETTERCD_MAGIC_WINDOW

# 24i. non-interactive cd - still toggles (regression pin; 2 redirected → not interactive)
_BETTERCD_LAST_DASH=""; _BETTERCD_MAGIC_UNTIL=""
mkdir -p "$TMP/mdash"; cd "$TMP/mdash"; cd "$TMP"
cd - >/dev/null 2>&1
[ "$PWD" = "$TMP/mdash" ]; check "magic: non-interactive cd - still toggles" $?
cd "$TMP"; rm -rf "$TMP/mdash"

# 24j. non-interactive cd -- keeps old delegate behavior (no menu, no hang)
cd -- >/dev/null 2>&1 </dev/null; check "magic: non-interactive cd -- delegates safely" $?
cd "$TMP"

# 24k. menu list builder helpers: home-rel display + nthline pick
[ "$(HOME=/h __bettercd_home_rel /h/x/y)" = '~/x/y' ]; check "magic: home-rel path display" $?
[ "$(__bettercd_home_rel /var/tmp)" = /var/tmp ];      check "magic: non-home path unchanged" $?
list="/a
/b
/c"
[ "$(__bettercd_nthline "$list" 0)" = /a ] && [ "$(__bettercd_nthline "$list" 2)" = /c ]
check "magic: nthline picks the right row" $?

# 25. vanished cd - target: moved → auto-follow; deleted → clean message
if [ -n "${ZSH_VERSION-}${BASH_VERSION-}" ]; then
    _BETTERCD_FORCE_INTERACTIVE=1
    mkdir -p "$TMP/van/orig" && cd "$TMP/van/orig" && cd "$TMP/van"
    # seed the inode record the way precmd would (suite has no prompt loop)
    __bettercd_anim_precmd >/dev/null 2>&1
    _BETTERCD_LASTPWD="$TMP/van"
    ino="$(ls -di "$TMP/van/orig")"; ino="${ino%%[!0-9]*}"
    _BETTERCD_INOS="$ino $TMP/van/orig
$_BETTERCD_INOS"
    OLDPWD="$TMP/van/orig"
    mv "$TMP/van/orig" "$TMP/van/renamed"
    cd - >/dev/null 2>"$TMP/.vanerr"
    [ "$PWD" = "$TMP/van/renamed" ] && grep -q "is now" "$TMP/.vanerr"
    check "vanished: moved dir auto-followed via inode" $?
    cd "$TMP/van"
    OLDPWD="$TMP/van/renamed"
    rm -rf "$TMP/van/renamed"
    cd - >/dev/null 2>"$TMP/.vanerr"
    rc=$?
    [ $rc -ne 0 ] && grep -q "does not exist there anymore" "$TMP/.vanerr" && [ "$PWD" = "$TMP/van" ]
    check "vanished: deleted dir gets clean message, rc 1" $?
    # non-interactive keeps stock failure (no pretty message)
    unset _BETTERCD_FORCE_INTERACTIVE
    OLDPWD="$TMP/van/gone-zzz"
    cd - >/dev/null 2>"$TMP/.vanerr" </dev/null
    rc=$?
    [ $rc -ne 0 ] && ! grep -q "does not exist there anymore" "$TMP/.vanerr"
    check "vanished: non-interactive keeps stock error" $?
    cd "$TMP"
fi

# 26. one-time history backlog seed (fallback path; zoxide absent in suite env)
if [ -n "${ZSH_VERSION-}${BASH_VERSION-}" ] && ! command -v zoxide >/dev/null 2>&1; then
    mkdir -p "$TMP/seedhome/projA" "$TMP/seedhome/projB"
    HISTFILE="$TMP/.fakehist"
    {
        printf ': 1700000001:0;cd %s/seedhome/projA\n' "$TMP"
        printf 'ls -la\n'
        printf ': 1700000002:0;cd relative-skipped\n'
        printf 'cd %s/seedhome/projB\n' "$TMP"
    } > "$HISTFILE"
    _BETTERCD_SEEDED=""; _BETTERCD_RECENT=""
    __bettercd_seed_recent
    case "$_BETTERCD_RECENT" in
        *"$TMP/seedhome/projB"*"$TMP/seedhome/projA"*) ok ;;   # newest first
        *) bad "seed: history backlog absolute cds, newest first" ;;
    esac
    case "$_BETTERCD_RECENT" in
        *relative-skipped*) bad "seed: relative cd entries skipped" ;;
        *) ok ;;
    esac
    __bettercd_seed_recent   # second call: no duplicate growth
    before_len=${#_BETTERCD_RECENT}
    __bettercd_seed_recent
    [ "${#_BETTERCD_RECENT}" -eq "$before_len" ]; check "seed: one-time only" $?
    unset HISTFILE; _BETTERCD_SEEDED=""; _BETTERCD_RECENT=""
elif command -v zoxide >/dev/null 2>&1; then
    printf 'skip: zoxide present — history-fallback seed path not exercised here\n'
fi

# 27. history REPLAY + zoxide/history MERGE + bettercd places -----------------
# Stubs a fake `zoxide` on PATH so the merge path runs deterministically
# regardless of whether the host has a real zoxide (never touches a real db).
if [ -n "${ZSH_VERSION-}${BASH_VERSION-}" ]; then
    cd "$TMP"
    mkdir -p "$TMP/rp/base/sub" "$TMP/rp/base/sub2" "$TMP/rp/uniq/lone" \
             "$TMP/rp/a1/dupname" "$TMP/rp/a2/dupname" "$TMP/rp/zonly"

    # fake zoxide: `query -l` prints uniq (a join base), base (dup vs history),
    # and zonly (zoxide-only). Paths are baked in at write time.
    mkdir -p "$TMP/fakebin"
    cat > "$TMP/fakebin/zoxide" <<STUB
#!/bin/sh
[ "\$1" = query ] && printf '%s\n' "$TMP/rp/uniq" "$TMP/rp/base" "$TMP/rp/zonly" "$TMP/rp/a1" "$TMP/rp/a2"
exit 0
STUB
    chmod +x "$TMP/fakebin/zoxide"
    rp_oldpath="$PATH"; PATH="$TMP/fakebin:$PATH"; export PATH

    HISTFILE="$TMP/.rphist"
    {
        printf ': 1700000001:0;cd %s/rp/base\n' "$TMP"   # absolute anchor
        printf 'cd sub\n'                                # relative chain
        printf 'cd ..\n'
        printf 'cd sub2\n'
        printf 'ls -la\n'
        printf 'cd ~\n'                                  # ~ anchor → HOME
        printf 'z jump-somewhere\n'                      # unresolvable jump → cwd unknown
        printf 'cd lone\n'                               # lone name after jump → join via uniq
        printf 'cd %s/rp/a1\n' "$TMP"                    # re-anchor
        printf 'z jump-again\n'
        printf 'cd dupname\n'                            # ambiguous (a1 & a2) → dropped
    } > "$HISTFILE"

    _BETTERCD_SEEDED=""; _BETTERCD_RECENT=""; _BETTERCD_SEED_Z=""; _BETTERCD_SEED_H=""
    __bettercd_seed_recent

    # 27a. absolute anchor + relative chain (sub / .. / sub2) all resolved
    case "$_BETTERCD_RECENT" in *"$TMP/rp/base/sub2"*) ok ;; *) bad "replay: relative chain resolves (sub2)" ;; esac
    case "$_BETTERCD_RECENT" in *"$TMP/rp/base/sub"*)  ok ;; *) bad "replay: relative chain resolves (sub)"  ;; esac

    # 27b. ~ anchor → HOME
    case "$_BETTERCD_RECENT" in *"$HOME"*) ok ;; *) bad "replay: ~ anchor resolves to HOME" ;; esac

    # 27c. constraint join: lone `cd lone` resolved via the (zoxide-known) uniq base
    case "$_BETTERCD_RECENT" in *"$TMP/rp/uniq/lone"*) ok ;; *) bad "replay: constraint-join resolves lone name" ;; esac

    # 27d. ambiguous `cd dupname` (a1 & a2 both match) → dropped, honestly
    case "$_BETTERCD_RECENT" in *dupname*) bad "replay: ambiguous name dropped" ;; *) ok ;; esac

    # 27e. merge dedup: base is in BOTH zoxide and history → appears exactly once
    dupn="$(printf '%s\n' "$_BETTERCD_RECENT" | grep -cx "$TMP/rp/base")"
    [ "$dupn" -eq 1 ]; check "merge: zoxide+history dedup (base once)" $?

    # 27f. zoxide-only dir is present in the pool
    case "$_BETTERCD_RECENT" in *"$TMP/rp/zonly"*) ok ;; *) bad "merge: zoxide-only dir present" ;; esac

    # 27g. bettercd places lists them, numbered
    places="$(bettercd places 2>/dev/null)"
    case "$places" in *"$TMP/rp/zonly"*) ok ;; *) bad "places: lists pool entries" ;; esac
    printf '%s\n' "$places" | grep -q '^[[:space:]]*1[[:space:]]'; check "places: rows are numbered" $?

    # 27h. places source tags: zoxide-only → zoxide; history-only chain → history
    printf '%s\n' "$places" | grep "$TMP/rp/zonly" | grep -q 'zoxide'
    check "places: zoxide-only tagged zoxide" $?
    printf '%s\n' "$places" | grep "$TMP/rp/base/sub2" | grep -q 'history'
    check "places: history-only tagged history" $?

    # 27i. places -n <k> limits the row count
    plim="$(bettercd places -n 2 2>/dev/null | grep -c '/')"
    [ "$plim" -le 2 ]; check "places: -n limits row count" $?
    bettercd places -n abc >/dev/null 2>&1; [ $? -ne 0 ]; check "places: -n rejects non-numeric" $?

    # 27j. one-time only: a second seed does not grow the pool
    seed_len=${#_BETTERCD_RECENT}
    __bettercd_seed_recent
    [ "${#_BETTERCD_RECENT}" -eq "$seed_len" ]; check "merge: seed is one-time only" $?

    PATH="$rp_oldpath"; export PATH
    unset HISTFILE; _BETTERCD_SEEDED=""; _BETTERCD_RECENT=""; _BETTERCD_SEED_Z=""; _BETTERCD_SEED_H=""
    cd "$TMP"
fi

# 28. F1-F7 dropdown row model (pure helpers — the interactive loop is tty-only
# and verified live; these pin the fork-free building blocks it composes) -------
cd "$TMP"

# 28a. lowercase helper (fork-free) + fuzzy subsequence matcher
__bettercd_lc "AbC/XyZ"; [ "$_bcd_lc" = "abc/xyz" ]; check "lc: lowercases mixed case" $?
__bettercd_fuzzy crb "$HOME/Creations/bettercd"; check "fuzzy: 'crb' subsequence matches" $?
__bettercd_fuzzy CRB "$HOME/Creations/bettercd"; check "fuzzy: case-insensitive match" $?
if __bettercd_fuzzy zqx "$HOME/Creations/bettercd"; then bad "fuzzy: non-subsequence excluded"; else ok; fi
__bettercd_fuzzy "" "anything"; check "fuzzy: empty query matches all" $?

# 28b. pad helper: truncates with ellipsis, pads short strings to width
__bettercd_pad short 8; [ "$_bcd_pad_out" = "short   " ]; check "pad: pads to width" $?
__bettercd_pad abcdefghij 5; case "$_bcd_pad_out" in abcd*) ok ;; *) bad "pad: truncates long" ;; esac

# 28c. F1 pins: toggle persists to an atomically-written file; load restores order
_BETTERCD_PINS_LOADED=""; _BETTERCD_PINS=""
mkdir -p "$TMP/pin1" "$TMP/pin2"
__bettercd_pin_toggle "$TMP/pin1"
__bettercd_pin_toggle "$TMP/pin2"
__bettercd_is_pinned "$TMP/pin1"; check "pin: toggle marks pinned" $?
pinfile="$HOME/.config/bettercd/pins"
[ -f "$pinfile" ]; check "pin: persists to file" $?
case "$(cat "$pinfile")" in *"$TMP/pin1"*"$TMP/pin2"*) ok ;; *) bad "pin: file keeps pin order" ;; esac
# atomicity: the persist path must go through a temp file + mv (grep the source)
grep -q 'command mv -f' "$BETTERCD_SH"; check "pin: write uses temp+mv (atomic)" $?
# reload from file restores pins
_BETTERCD_PINS_LOADED=""; _BETTERCD_PINS=""
__bettercd_pins_load
__bettercd_is_pinned "$TMP/pin2"; check "pin: reload restores from file" $?
# unpin removes it, file updates
__bettercd_pin_toggle "$TMP/pin1"
if __bettercd_is_pinned "$TMP/pin1"; then bad "pin: unpin removes"; else ok; fi
case "$(cat "$pinfile")" in *pin1*) bad "pin: unpin drops from file" ;; *) ok ;; esac
_BETTERCD_PINS_LOADED=""; _BETTERCD_PINS=""

# 28d. F2 project mark: creates .project/ + empty status; second call is a no-op
mkdir -p "$TMP/pm"
__bettercd_project_mark "$TMP/pm"; check "project-mark: rc0 on first mark" $?
[ -d "$TMP/pm/.project" ] && [ -f "$TMP/pm/.project/status" ]; check "project-mark: creates .project/status" $?
__bettercd_project_mark "$TMP/pm"; [ $? -ne 0 ]; check "project-mark: rc1 when already marked" $?

# 28e. F5 detail metadata: version + shipped from a .project/status fixture
mkdir -p "$TMP/dv/.project"
printf 'version: v1.2.3\nlast_shipped: v1.2.3\n' > "$TMP/dv/.project/status"
[ "$(__bettercd_rowver "$TMP/dv")" = "v1.2.3" ]; check "detail: version from .project/status" $?
[ "$(__bettercd_rowshipped "$TMP/dv")" = "y" ]; check "detail: shipped y when last_shipped==version" $?
printf 'version: v2.0.0\nlast_shipped: v1.0.0\n' > "$TMP/dv/.project/status"
[ "$(__bettercd_rowshipped "$TMP/dv")" = "n" ]; check "detail: shipped n when mismatch" $?
mkdir -p "$TMP/dv2"
[ -z "$(__bettercd_rowshipped "$TMP/dv2")" ]; check "detail: shipped blank without .project" $?
[ "$(__bettercd_rowver "$TMP/dv2")" = "-" ]; check "detail: version - for plain dir" $?
case "$(__bettercd_rowmtime "$TMP/dv2")" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ok ;; *) bad "detail: mtime is YYYY-MM-DD" ;; esac

# 28f. F4 git-state classifier (needs git) — clean / modified / untracked
if command -v git >/dev/null 2>&1; then
    for gs in gclean gmod guntr; do
        mkdir -p "$TMP/$gs"
        ( cd "$TMP/$gs" && git init -q && git config user.email a@b.c && git config user.name t \
          && echo x > f && git add f && git commit -qm init ) >/dev/null 2>&1
    done
    ( cd "$TMP/gmod" && echo y >> f ) >/dev/null 2>&1
    ( cd "$TMP/guntr" && echo z > brandnew ) >/dev/null 2>&1
    [ "$(__bettercd_gitclass "$TMP/gclean")" = clean ]; check "gitclass: clean repo" $?
    [ "$(__bettercd_gitclass "$TMP/gmod")" = mod ];     check "gitclass: tracked modification" $?
    [ "$(__bettercd_gitclass "$TMP/guntr")" = untr ];   check "gitclass: untracked wins" $?
    [ -z "$(__bettercd_gitclass "$TMP/dv2")" ];         check "gitclass: non-git dir is blank" $?
fi

# 28g. metadata caches populate once and are reused (idempotent records)
_BETTERCD_C=""; _BETTERCD_D=""
__bettercd_meta_c "$TMP/dv"; c1="$_bcd_c_proj"
__bettercd_meta_c "$TMP/dv"; [ "$_bcd_c_proj" = "$c1" ] && [ "$c1" = 1 ]
check "meta_c: project flag cached and stable" $?
recs="$(printf '%s' "$_BETTERCD_C" | grep -c "$TMP/dv")"
[ "$recs" -eq 1 ]; check "meta_c: one cache record per path" $?
__bettercd_meta_inval "$TMP/dv"
case "$_BETTERCD_C" in *"$TMP/dv"*) bad "meta_inval: drops the record" ;; *) ok ;; esac

# 28h. F6 name sort keeps EVERY entry (regression: an unterminated last line was
# dropped by the sort's while-read before the trailing-newline fix)
sorted="$(printf '%s\n' "$TMP/zeb
$TMP/alp
$TMP/mid" | __bettercd_sort_name)"
cnt="$(printf '%s\n' "$sorted" | grep -c .)"
[ "$cnt" -eq 3 ]; check "sort-name: keeps all entries (no last-line drop)" $?
case "$sorted" in "$TMP/alp"*) ok ;; *) bad "sort-name: alphabetical order" ;; esac

# 28. autoreload: cd notices a newer source file and re-sources it (zero-fork check)
if [ -n "${ZSH_VERSION-}${BASH_VERSION-}" ]; then
    _BETTERCD_FORCE_INTERACTIVE=1
    ARL="$TMP/arl"; mkdir -p "$ARL"
    cp "$BETTERCD_SH" "$ARL/bcd.sh"
    XDG_CONFIG_HOME="$ARL/cfg"
    . "$ARL/bcd.sh"
    v0="$BETTERCD_VERSION"
    sleep 1   # mtime resolution
    sed 's/^BETTERCD_VERSION=.*/BETTERCD_VERSION="99.99.99-test"/' "$ARL/bcd.sh" > "$ARL/bcd.sh.new" \
        && mv "$ARL/bcd.sh.new" "$ARL/bcd.sh"
    cd "$TMP" >/dev/null 2>&1
    [ "$BETTERCD_VERSION" = "99.99.99-test" ] && [ "$v0" != "99.99.99-test" ]
    check "autoreload: cd picked up the edited source" $?
    # opt-out respected
    sleep 1
    sed 's/^BETTERCD_VERSION=.*/BETTERCD_VERSION="88.88.88-test"/' "$ARL/bcd.sh" > "$ARL/bcd.sh.new" \
        && mv "$ARL/bcd.sh.new" "$ARL/bcd.sh"
    BETTERCD_AUTORELOAD=0
    cd "$TMP" >/dev/null 2>&1
    [ "$BETTERCD_VERSION" = "99.99.99-test" ]
    check "autoreload: BETTERCD_AUTORELOAD=0 stays put" $?
    unset BETTERCD_AUTORELOAD
    XDG_CONFIG_HOME="$HOME/.config"
    . "$BETTERCD_SH"   # restore the real one for any later tests
    unset _BETTERCD_FORCE_INTERACTIVE
fi

# 29. cd --help shows the big help, exits 0 (and never tries to cd)
out="$(cd --help 2>&1)"; rc=$?
[ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'a better cd' && printf '%s' "$out" | grep -q 'THE DROPDOWN'
check "cd --help prints the big help" $?

# 30. long-flag surface: every cd --X routes, unknown flags never create dirs
cd "$TMP"
cd --version 2>/dev/null | grep -q "bettercd"; check "cd --version" $?
cd --status  2>/dev/null | grep -q "cd mode"; check "cd --status" $?
cd --config  2>/dev/null | grep -q "prefs"; check "cd --config" $?
cd --update  >/dev/null 2>&1; check "cd --update exits 0" $?
out="$(cd --frobnicate 2>&1)"; rc=$?
[ $rc -ne 0 ] && printf '%s' "$out" | grep -q "unknown flag" && [ ! -d "$TMP/--frobnicate" ]
check "unknown --flag: message, rc 1, NO dir created" $?

# 31. spaced dot-runs: cd ... goes up two (never creates a dir named ...)
mkdir -p "$TMP/dots/a/b" && cd "$TMP/dots/a/b"
cd ... 2>/dev/null
[ "$PWD" = "$TMP/dots" ] && [ ! -d "$TMP/dots/a/b/..." ]
check "cd ... (spaced) goes up two" $?
cd "$TMP"

# --- results -----------------------------------------------------------------
printf '%s: %d passed, %d failed\n' "${BETTERCD_TEST_LABEL:-suite}" "$PASS" "$FAIL"
rm -rf "$TMP"
[ "$FAIL" -eq 0 ]
