#!/bin/sh
# shellcheck disable=SC2164,SC2319,SC2103,SC1090,SC2181
#   cd failing (and inspecting $? after tests) is exactly what this suite tests.
# bettercd zoxide-mode test — stubs __zoxide_z to prove precedence rules
# deterministically (never touches a real zoxide database).
# Usage: BETTERCD_SH=/path/to/bettercd.sh <shell> tests/zoxide_stub.sh

BETTERCD_SH="${BETTERCD_SH:-$(dirname "$0")/../bettercd.sh}"
case "$BETTERCD_SH" in /*) ;; *) BETTERCD_SH="$PWD/$BETTERCD_SH" ;; esac

TMP="$(mktemp -d)" || exit 1
HOME="$TMP/home"; export HOME
mkdir -p "$HOME"
unset CDPATH
cd "$TMP" || exit 1

PASS=0; FAIL=0
check() { if [ "$2" -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; fi; }

# Simulate `zoxide init --cmd cd`: a cd function backed by a fake frecency db
FAKE_TARGET="$TMP/frecent/project"
mkdir -p "$FAKE_TARGET"
__zoxide_z() {
    if [ "$#" -eq 0 ]; then builtin cd ~ && return
    elif [ "$#" -eq 1 ] && [ -d "$1" ]; then builtin cd "$1" && return
    elif [ "$1" = "proj" ]; then builtin cd "$FAKE_TARGET" && return  # fake db match
    else printf 'zoxide: no match found\n' >&2; return 1
    fi
}
cd() { __zoxide_z "$@"; }

. "$BETTERCD_SH"

# mode detection saw a zoxide-owned cd
[ "$_BETTERCD_MODE" = "zoxide" ]; check "detects zoxide-owned cd (mode=zoxide)" $?

# 1. bare name with a zoxide match → fuzzy jump WINS over auto-create
cd proj 2>/dev/null
[ "$PWD" = "$FAKE_TARGET" ] && [ ! -d "$TMP/proj" ]
check "bare-name zoxide match wins over create" $?
cd "$TMP"

# 2. trailing slash forces create even when zoxide would match
cd proj/ 2>/dev/null
[ "$PWD" = "$TMP/proj" ] && [ -d "$TMP/proj" ]
check "trailing slash forces create over zoxide match" $?
bettercd undo 2>/dev/null
[ ! -d "$TMP/proj" ]; check "undo after forced create" $?

# 3. no zoxide match → falls through to auto-create under cwd
cd fresh/sub 2>/dev/null
[ "$PWD" = "$TMP/fresh/sub" ]; check "no-match falls through to auto-create" $?
bettercd undo 2>/dev/null

# 4. existing dir still passes through the zoxide delegate
mkdir plain && cd plain
[ "$PWD" = "$TMP/plain" ]; check "existing dir passthrough in zoxide mode" $?

printf '%s: %d passed, %d failed\n' "${BETTERCD_TEST_LABEL:-zoxide-stub}" "$PASS" "$FAIL"
cd / && rm -rf "$TMP"
[ "$FAIL" -eq 0 ]
