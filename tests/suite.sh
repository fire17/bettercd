#!/bin/sh
# shellcheck disable=SC2164,SC2319,SC2103,SC1090,SC2181,SC2217,SC2034
#   cd failing, inspecting $? after it, and feeding its [y/N] prompt via stdin
#   are exactly what this suite tests.
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

# --- results -----------------------------------------------------------------
printf '%s: %d passed, %d failed\n' "${BETTERCD_TEST_LABEL:-suite}" "$PASS" "$FAIL"
rm -rf "$TMP"
[ "$FAIL" -eq 0 ]
