#!/bin/sh
# shellcheck disable=SC2016
# bettercd installer — https://github.com/fire17/bettercd
#
# What this does (and nothing else):
#   1. Downloads bettercd.sh to ~/.local/share/bettercd/  (or uses a local copy)
#   2. Backs up your shell rc file
#   3. Appends a clearly-marked source block to it (idempotent)
# Uninstall: delete the block between the >>> bettercd >>> markers.

set -e

REPO_RAW="https://raw.githubusercontent.com/fire17/bettercd/main"
DEST_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/bettercd"
MARK_OPEN="# >>> bettercd >>>"
MARK_CLOSE="# <<< bettercd <<<"

say() { printf '%s\n' "$*" >&2; }

# 1. get bettercd.sh
mkdir -p "$DEST_DIR"
here="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ -n "$here" ] && [ -f "$here/bettercd.sh" ]; then
    cp "$here/bettercd.sh" "$DEST_DIR/bettercd.sh"
    say "bettercd: installed from local checkout → $DEST_DIR/bettercd.sh"
elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "$REPO_RAW/bettercd.sh" -o "$DEST_DIR/bettercd.sh"
    say "bettercd: downloaded → $DEST_DIR/bettercd.sh"
elif command -v wget >/dev/null 2>&1; then
    wget -q "$REPO_RAW/bettercd.sh" -O "$DEST_DIR/bettercd.sh"
    say "bettercd: downloaded → $DEST_DIR/bettercd.sh"
else
    say "bettercd: need curl or wget (or run install.sh from a cloned repo)"; exit 1
fi

# 2. pick the rc file for the user's login shell
case "${SHELL:-}" in
    */zsh)  rc="${ZDOTDIR:-$HOME}/.zshrc" ;;
    */bash) if [ -f "$HOME/.bashrc" ]; then rc="$HOME/.bashrc"; else rc="$HOME/.bash_profile"; fi ;;
    *)      rc="$HOME/.profile" ;;
esac
touch "$rc"

# 3. idempotent marked block (after a backup)
if grep -q "$MARK_OPEN" "$rc" 2>/dev/null; then
    say "bettercd: already installed in $rc — nothing to do."
else
    cp "$rc" "$rc.bettercd-backup.$(date +%Y%m%d-%H%M%S)"
    {
        printf '\n%s\n' "$MARK_OPEN"
        printf '# keep this AFTER any `zoxide init` line\n'
        printf 'source "%s/bettercd.sh"\n' "$DEST_DIR"
        printf '%s\n' "$MARK_CLOSE"
    } >> "$rc"
    say "bettercd: added source block to $rc (backup saved next to it)"
fi

# 4. friendly next steps
if ! command -v zoxide >/dev/null 2>&1; then
    say ""
    say "note: zoxide not found — bettercd works without it, but for fuzzy jumps:"
    say "      https://github.com/ajeetdsouza/zoxide#installation"
fi
say ""
say "done. restart your shell (or: source $rc), then run:  bettercd doctor"
