#!/bin/sh
# shellcheck disable=SC2164,SC2319,SC2103,SC1090,SC2181,SC2217,SC2034,SC3044,SC2154,SC2088
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
unset BETTERCD_MAGIC

# 24g. window override respected (600s)
BETTERCD_MAGIC_WINDOW=600; _BETTERCD_LAST_DASH=""; _BETTERCD_MAGIC_UNTIL=""
__bettercd_dash_mode 2000   # classic, arms LAST_DASH
__bettercd_dash_mode 2030   # magic → UNTIL = 2030+600
[ "$_BETTERCD_MAGIC_UNTIL" = 2630 ]; check "magic: window override respected" $?
unset BETTERCD_MAGIC_WINDOW; _BETTERCD_LAST_DASH=""; _BETTERCD_MAGIC_UNTIL=""

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

# --- results -----------------------------------------------------------------
printf '%s: %d passed, %d failed\n' "${BETTERCD_TEST_LABEL:-suite}" "$PASS" "$FAIL"
rm -rf "$TMP"
[ "$FAIL" -eq 0 ]
