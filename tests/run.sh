#!/bin/sh
# bettercd test runner — runs the suite under every available shell.
# Usage: tests/run.sh   (from the repo root or anywhere)

here="$(cd "$(dirname "$0")" && pwd)"
BETTERCD_SH="$here/../bettercd.sh"
export BETTERCD_SH

failed=0
ran=0

for shell in bash zsh; do
    if ! command -v "$shell" >/dev/null 2>&1; then
        printf 'skip: %s not installed\n' "$shell"
        continue
    fi
    for t in suite zoxide_stub; do
        ran=$((ran + 1))
        if BETTERCD_TEST_LABEL="$shell/$t" "$shell" "$here/$t.sh"; then :; else
            failed=$((failed + 1))
            printf '>>> %s/%s FAILED\n' "$shell" "$t" >&2
        fi
    done
done

# POSIX smoke test: bettercd must at least source + run under plain sh/dash
for shell in dash sh; do
    if command -v "$shell" >/dev/null 2>&1; then
        ran=$((ran + 1))
        if "$shell" -c ". '$BETTERCD_SH' && cd /tmp && bettercd version >/dev/null"; then
            printf '%s/smoke: 1 passed, 0 failed\n' "$shell"
        else
            failed=$((failed + 1))
            printf '>>> %s/smoke FAILED\n' "$shell" >&2
        fi
        break
    fi
done

if [ "$failed" -eq 0 ]; then
    printf 'ALL GREEN (%d test files)\n' "$ran"
else
    printf '%d/%d test file(s) failed\n' "$failed" "$ran" >&2
    exit 1
fi
