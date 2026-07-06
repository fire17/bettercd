#!/bin/sh
# shellcheck disable=SC3044,SC3054,SC2154,SC2164,SC2016
#   SC3044/SC3054/SC2154: declare/functions[] are bash/zsh-only and always
#   guarded by $BASH_VERSION/$ZSH_VERSION checks. SC2164: one-line cd
#   delegates propagate their exit status by design. SC2016: literal hints.
# bettercd — a better cd: zoxide-aware, auto-mkdir, with undo.
# https://github.com/fire17/bettercd
#
# Source this file from your shell rc, AFTER any `zoxide init` line:
#   source /path/to/bettercd.sh
#
# Pure shell (bash/zsh, POSIX-leaning). No dependencies.
# zoxide and fzf are optional enhancers — bettercd composes with them
# if present and works fine without them.

BETTERCD_VERSION="0.1.0"

# --- paradigm detection (runs once, at source time) -------------------------
# Decide what "plain cd" means for this user, and never change it silently:
#   zoxide  — user ran `zoxide init --cmd cd`; delegate to __zoxide_z
#   prev    — user had their own cd function; we capture and delegate to it
#   builtin — plain builtin cd (still honors CDPATH)
__bettercd_detect() {
    _BETTERCD_MODE="builtin"
    _bcd_body=""
    if [ -n "${ZSH_VERSION-}" ]; then
        _bcd_body="${functions[cd]-}"
    elif [ -n "${BASH_VERSION-}" ]; then
        _bcd_body="$(declare -f cd 2>/dev/null)"
    fi
    case "$_bcd_body" in
        *__bettercd*) return 0 ;;  # re-source: keep previous detection
        *__zoxide*)   _BETTERCD_MODE="zoxide" ;;
        "")           _BETTERCD_MODE="builtin" ;;
        *)
            # Custom cd function: capture it so we can keep delegating to it.
            if [ -n "${ZSH_VERSION-}" ]; then
                functions[__bettercd_prev_cd]="${functions[cd]}" &&
                    _BETTERCD_MODE="prev"
            elif [ -n "${BASH_VERSION-}" ]; then
                eval "__bettercd_prev_cd() $(declare -f cd | sed '1d')" 2>/dev/null &&
                    _BETTERCD_MODE="prev"
            fi
            ;;
    esac
    unset _bcd_body
}
__bettercd_detect

# --- helpers -----------------------------------------------------------------

# The raw builtin cd. (zsh's `command cd` runs the external no-op /usr/bin/cd,
# so bash/zsh must use `builtin` explicitly; plain sh has no `builtin`.)
if [ -n "${ZSH_VERSION-}" ] || [ -n "${BASH_VERSION-}" ]; then
    __bettercd_cd() { builtin cd "$@"; }
else
    __bettercd_cd() { command cd "$@"; }
fi

# Plain cd, exactly as the user had it before bettercd.
__bettercd_delegate() {
    case "$_BETTERCD_MODE" in
        zoxide) __zoxide_z "$@" ;;
        prev)   __bettercd_prev_cd "$@" ;;
        *)      __bettercd_cd "$@" ;;
    esac
}

# Normalize a path textually against $PWD: resolves ".", "..", "//".
# (Textual on purpose: the target doesn't exist yet, so readlink can't help.)
__bettercd_normalize() {
    case "$1" in
        /*) _bcd_in="$1" ;;
        *)  _bcd_in="$PWD/$1" ;;
    esac
    _bcd_out=""
    _bcd_rest="$_bcd_in/"
    while [ -n "$_bcd_rest" ]; do
        _bcd_seg="${_bcd_rest%%/*}"
        _bcd_rest="${_bcd_rest#*/}"
        case "$_bcd_seg" in
            ''|'.') ;;
            '..')   _bcd_out="${_bcd_out%/*}" ;;
            *)      _bcd_out="$_bcd_out/$_bcd_seg" ;;
        esac
    done
    printf '%s\n' "${_bcd_out:-/}"
}

# Single-quote a string for safe display in a copy-pasteable command.
__bettercd_sq() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

__bettercd_interactive() {
    [ -n "${_BETTERCD_FORCE_INTERACTIVE-}" ] && return 0
    [ -t 0 ] && [ -t 2 ]
}

__bettercd_clear_miss() { _BETTERCD_LAST_MISS=""; }

# mkdir -p the target, cd into it, remember exactly what we created.
__bettercd_create_and_cd() {
    _bcd_target="$1"
    # deepest existing ancestor
    _bcd_anc="$_bcd_target"
    while [ ! -d "$_bcd_anc" ] && [ "$_bcd_anc" != "/" ]; do
        _bcd_anc="${_bcd_anc%/*}"
        [ -n "$_bcd_anc" ] || _bcd_anc="/"
    done
    # dirs that will be newly created, deepest first
    _bcd_created=""
    _bcd_p="$_bcd_target"
    while [ "$_bcd_p" != "$_bcd_anc" ] && [ -n "$_bcd_p" ] && [ "$_bcd_p" != "/" ]; do
        _bcd_created="$_bcd_created$_bcd_p
"
        _bcd_p="${_bcd_p%/*}"
        [ -n "$_bcd_p" ] || _bcd_p="/"
    done
    _bcd_from="$PWD"
    if ! command mkdir -p -- "$_bcd_target"; then
        printf 'bettercd: could not create %s\n' "$_bcd_target" >&2
        return 1
    fi
    if ! __bettercd_delegate "$_bcd_target"; then
        printf 'bettercd: created %s but could not enter it\n' "$_bcd_target" >&2
        return 1
    fi
    _BETTERCD_UNDO_FROM="$_bcd_from"
    _BETTERCD_UNDO_CREATED="$_bcd_created"
    _BETTERCD_UNDO_TARGET="$_bcd_target"
    __bettercd_clear_miss
    if [ "${BETTERCD_QUIET-0}" != 1 ]; then
        _bcd_n=0
        while IFS= read -r _bcd_line; do
            [ -n "$_bcd_line" ] && _bcd_n=$((_bcd_n + 1))
        done <<__BCD_EOF__
$_bcd_created
__BCD_EOF__
        _bcd_raw="cd $(__bettercd_sq "$_bcd_from")"
        while IFS= read -r _bcd_line; do
            [ -n "$_bcd_line" ] && _bcd_raw="$_bcd_raw && rmdir $(__bettercd_sq "$_bcd_line")"
        done <<__BCD_EOF__
$_bcd_created
__BCD_EOF__
        printf 'bettercd: created %s new dir(s) → %s\n' "$_bcd_n" "$_bcd_target" >&2
        printf '          undo: bettercd undo    (or: %s)\n' "$_bcd_raw" >&2
    fi
    return 0
}

# --- the cd wrapper ----------------------------------------------------------
cd() {
    # fast passthroughs: no args, multiple args, flags, "-", dir-stack refs
    if [ "$#" -ne 1 ]; then
        __bettercd_delegate "$@" && __bettercd_clear_miss
        return $?
    fi
    case "$1" in
        '' | - | -- )
            __bettercd_delegate "$@" && __bettercd_clear_miss
            return $? ;;
        -* | +* )
            # flags (-P/-L/-e/…) and zsh dir-stack refs (+2/-2): builtin semantics
            __bettercd_cd "$@" && __bettercd_clear_miss
            return $? ;;
    esac

    # happy path: the directory exists — zero-overhead passthrough
    if [ -d "$1" ]; then
        __bettercd_delegate "$1" && __bettercd_clear_miss
        return $?
    fi

    # exists but is a file → go to its parent (with a note)
    if [ -e "$1" ] && [ ! -d "$1" ]; then
        _bcd_parent="$(dirname -- "$1")"
        printf 'bettercd: %s is a file → cd %s\n' "$1" "$_bcd_parent" >&2
        __bettercd_delegate "$_bcd_parent" && __bettercd_clear_miss
        return $?
    fi

    # target doesn't exist ------------------------------------------------
    _bcd_force_create=""
    case "$1" in
        */) _bcd_force_create=1 ;;  # trailing slash = explicit "create it" intent
    esac

    # let the user's own cd try first (zoxide fuzzy jump, CDPATH, custom fn)
    if [ -z "$_bcd_force_create" ]; then
        if __bettercd_delegate "$1" 2>/dev/null; then
            __bettercd_clear_miss
            return 0
        fi
    fi

    if [ "${BETTERCD_AUTO_CREATE-1}" = 0 ]; then
        printf 'cd: no such file or directory: %s\n' "$1" >&2
        return 1
    fi

    _bcd_norm="$(__bettercd_normalize "$1")"

    # under the current directory → create it, tell the user, offer undo
    _bcd_base="$PWD"
    [ "$_bcd_base" = "/" ] && _bcd_base=""
    case "$_bcd_norm" in
        "$_bcd_base"/*)
            __bettercd_create_and_cd "$_bcd_norm"
            return $? ;;
    esac

    # outside the current directory → fail once with a hint; on an immediate
    # identical retry, ask for confirmation (interactive shells only)
    if [ "$_BETTERCD_LAST_MISS" = "$_bcd_norm" ] && __bettercd_interactive; then
        printf 'bettercd: create %s ? [y/N] ' "$_bcd_norm" >&2
        read -r _bcd_ans
        case "$_bcd_ans" in
            y|Y|yes|YES)
                __bettercd_create_and_cd "$_bcd_norm"
                return $? ;;
            *)
                __bettercd_clear_miss
                printf 'bettercd: not created.\n' >&2
                return 1 ;;
        esac
    fi
    _BETTERCD_LAST_MISS="$_bcd_norm"
    printf 'cd: no such file or directory: %s\n' "$1" >&2
    if __bettercd_interactive && [ "${BETTERCD_QUIET-0}" != 1 ]; then
        printf 'bettercd: outside the current dir — repeat the command to create it.\n' >&2
    fi
    return 1
}

# --- the bettercd command ----------------------------------------------------
bettercd() {
    case "${1-}" in
        undo)    __bettercd_undo ;;
        doctor)  shift; __bettercd_doctor "$@" ;;
        backup)  __bettercd_backup ;;
        status)  __bettercd_status ;;
        version|--version|-v) printf 'bettercd %s\n' "$BETTERCD_VERSION" ;;
        help|--help|-h|'')    __bettercd_help ;;
        *) printf 'bettercd: unknown command: %s (try: bettercd help)\n' "$1" >&2
           return 1 ;;
    esac
}

__bettercd_help() {
    cat <<'__BCD_EOF__'
bettercd — a better cd: zoxide-aware, auto-mkdir, with undo.

  cd <existing>        plain cd (zoxide-aware, zero overhead)
  cd <missing>         under cwd → mkdir -p + cd (with undo hint)
                       elsewhere → fails once; repeat → [y/N] create prompt
  cd <missing>/        trailing slash: always create (skips fuzzy jump)
  cd <file>            jumps to the file's parent directory

  bettercd undo        go back + remove the dirs the last cd created (rmdir only)
  bettercd doctor      check zoxide / fzf / cd-ownership; --fix to install
  bettercd backup      snapshot your current cd paradigm + how to restore it
  bettercd status      show mode, pending undo, version
  bettercd version     print version

  env: BETTERCD_AUTO_CREATE=0  disable auto-create
       BETTERCD_QUIET=1        suppress hints
__BCD_EOF__
}

__bettercd_undo() {
    if [ -z "${_BETTERCD_UNDO_CREATED-}" ]; then
        printf 'bettercd: nothing to undo\n' >&2
        return 1
    fi
    __bettercd_delegate "$_BETTERCD_UNDO_FROM" || return 1
    _bcd_kept=""
    _bcd_removed=0
    while IFS= read -r _bcd_d; do
        [ -n "$_bcd_d" ] || continue
        if command rmdir -- "$_bcd_d" 2>/dev/null; then
            _bcd_removed=$((_bcd_removed + 1))
        else
            [ -e "$_bcd_d" ] && _bcd_kept="$_bcd_kept $_bcd_d"
        fi
    done <<__BCD_EOF__
$_BETTERCD_UNDO_CREATED
__BCD_EOF__
    if [ ! -d "$_BETTERCD_UNDO_TARGET" ] && command -v zoxide >/dev/null 2>&1; then
        command zoxide remove "$_BETTERCD_UNDO_TARGET" 2>/dev/null
    fi
    printf 'bettercd: back in %s — removed %s dir(s)' "$PWD" "$_bcd_removed" >&2
    if [ -n "$_bcd_kept" ]; then
        printf '; kept (not empty):%s' "$_bcd_kept" >&2
    fi
    printf '\n' >&2
    _BETTERCD_UNDO_FROM="" _BETTERCD_UNDO_CREATED="" _BETTERCD_UNDO_TARGET=""
    return 0
}

__bettercd_status() {
    printf 'bettercd %s\n' "$BETTERCD_VERSION"
    printf '  cd mode:      %s\n' "$_BETTERCD_MODE"
    if [ -n "${_BETTERCD_UNDO_CREATED-}" ]; then
        printf '  pending undo: %s (from %s)\n' "$_BETTERCD_UNDO_TARGET" "$_BETTERCD_UNDO_FROM"
    else
        printf '  pending undo: none\n'
    fi
    printf '  auto-create:  %s\n' "$([ "${BETTERCD_AUTO_CREATE-1}" = 0 ] && echo off || echo on)"
}

# --- doctor ------------------------------------------------------------------
__bettercd_check() {  # $1 label, $2 ok(0/1), $3 fix hint
    if [ "$2" -eq 0 ]; then
        printf '  [ok] %s\n' "$1"
    else
        printf '  [!!] %s\n' "$1"
        [ -n "${3-}" ] && printf '       fix: %s\n' "$3"
        _bcd_doctor_bad=$((_bcd_doctor_bad + 1))
        _bcd_doctor_fixes="$_bcd_doctor_fixes$3
"
    fi
}

__bettercd_doctor() {
    _bcd_fix=""
    [ "${1-}" = "--fix" ] && _bcd_fix=1
    _bcd_doctor_bad=0
    _bcd_doctor_fixes=""
    printf 'bettercd doctor\n'

    # zoxide installed & working
    if command -v zoxide >/dev/null 2>&1; then
        __bettercd_check "zoxide installed ($(zoxide --version 2>/dev/null))" 0
        if zoxide query -l >/dev/null 2>&1; then
            __bettercd_check "zoxide database working" 0
        else
            __bettercd_check "zoxide database working" 1 "zoxide query -l failed — check ~/.local/share/zoxide"
        fi
    else
        __bettercd_check "zoxide installed" 1 "$(__bettercd_install_hint zoxide)"
    fi

    # zoxide hooked into this shell / owning cd
    if command -v __zoxide_z >/dev/null 2>&1; then
        __bettercd_check "zoxide initialized in this shell" 0
    else
        __bettercd_check "zoxide initialized in this shell" 1 \
            'add to your shell rc (before bettercd):  eval "$(zoxide init '"$(__bettercd_shell_name)"' --cmd cd)"'
    fi
    if [ "$_BETTERCD_MODE" = "zoxide" ]; then
        __bettercd_check "cd is zoxide-powered (fuzzy jump on miss)" 0
    else
        __bettercd_check "cd is zoxide-powered (mode: $_BETTERCD_MODE)" 1 \
            'use  zoxide init '"$(__bettercd_shell_name)"' --cmd cd  to let cd fuzzy-jump (bettercd composes with it)'
    fi

    # fuzzy interactive search
    if command -v fzf >/dev/null 2>&1; then
        __bettercd_check "fzf installed (interactive fuzzy: cdi / zi)" 0
    else
        __bettercd_check "fzf installed (interactive fuzzy: cdi / zi)" 1 "$(__bettercd_install_hint fzf)"
    fi

    # bettercd actually owns cd right now
    _bcd_owns=1
    if [ -n "${ZSH_VERSION-}" ]; then
        case "${functions[cd]-}" in *__bettercd*|*bettercd*) _bcd_owns=0 ;; esac
    elif [ -n "${BASH_VERSION-}" ]; then
        case "$(declare -f cd 2>/dev/null)" in *bettercd*) _bcd_owns=0 ;; esac
    fi
    __bettercd_check "bettercd owns cd (sourced after zoxide init)" "$_bcd_owns" \
        "move 'source bettercd.sh' AFTER the zoxide init line in your rc, then restart the shell"

    if [ "$_bcd_doctor_bad" -eq 0 ]; then
        printf 'all good.\n'
        return 0
    fi
    printf '%s issue(s) found.\n' "$_bcd_doctor_bad"
    if [ -n "$_bcd_fix" ]; then
        __bettercd_backup || return 1
        printf 'suggested fixes were listed above; package installs can be run now.\n'
        if command -v zoxide >/dev/null 2>&1 || ! __bettercd_interactive; then :; else
            printf 'install zoxide now? [y/N] ' >&2
            read -r _bcd_a
            case "$_bcd_a" in y|Y) __bettercd_run_install zoxide ;; esac
        fi
        if command -v fzf >/dev/null 2>&1 || ! __bettercd_interactive; then :; else
            printf 'install fzf now? [y/N] ' >&2
            read -r _bcd_a
            case "$_bcd_a" in y|Y) __bettercd_run_install fzf ;; esac
        fi
    else
        printf 'run  bettercd doctor --fix  to back up your setup and install what is missing.\n'
    fi
    return 1
}

__bettercd_shell_name() {
    if [ -n "${ZSH_VERSION-}" ]; then echo zsh
    elif [ -n "${BASH_VERSION-}" ]; then echo bash
    else echo sh; fi
}

__bettercd_install_hint() {
    if command -v brew >/dev/null 2>&1; then echo "brew install $1"
    elif command -v apt-get >/dev/null 2>&1; then echo "sudo apt-get install $1"
    elif command -v dnf >/dev/null 2>&1; then echo "sudo dnf install $1"
    elif command -v pacman >/dev/null 2>&1; then echo "sudo pacman -S $1"
    elif command -v cargo >/dev/null 2>&1; then echo "cargo install $1"
    else echo "see https://github.com/ajeetdsouza/zoxide#installation"; fi
}

__bettercd_run_install() {
    _bcd_cmd="$(__bettercd_install_hint "$1")"
    printf 'running: %s\n' "$_bcd_cmd" >&2
    eval "$_bcd_cmd"
}

# --- backup: save the user's current cd paradigm + how to restore it ---------
__bettercd_backup() {
    _bcd_bdir="${XDG_CONFIG_HOME:-$HOME/.config}/bettercd/backups/$(date -u +%Y%m%d-%H%M%S)"
    command mkdir -p -- "$_bcd_bdir" || return 1
    {
        printf '# what `cd` was at backup time\n'
        printf 'mode detected by bettercd: %s\n\n' "$_BETTERCD_MODE"
        if [ -n "${ZSH_VERSION-}" ]; then
            printf '%s\n' "${functions[cd]-<builtin cd>}"
        elif [ -n "${BASH_VERSION-}" ]; then
            declare -f cd 2>/dev/null || printf '<builtin cd>\n'
        fi
    } > "$_bcd_bdir/cd-function.txt"
    alias > "$_bcd_bdir/aliases.txt" 2>/dev/null
    for _bcd_rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
        [ -f "$_bcd_rc" ] && command cp -- "$_bcd_rc" "$_bcd_bdir/$(basename "$_bcd_rc").bak"
    done
    if command -v zoxide >/dev/null 2>&1; then
        zoxide query -l > "$_bcd_bdir/zoxide-paths.txt" 2>/dev/null
    fi
    cat > "$_bcd_bdir/RESTORE.md" <<__BCD_EOF__
# How to restore your previous cd setup

1. Your shell rc files were copied here as \`*.bak\` — to fully restore:
       cp <file>.bak ~/<file>
2. To just remove bettercd: delete the \`source .../bettercd.sh\` line
   (or the block between \`# >>> bettercd >>>\` and \`# <<< bettercd <<<\`)
   from your rc file, then restart your shell.
3. \`cd-function.txt\` shows exactly what \`cd\` was before (mode: $_BETTERCD_MODE).
4. \`zoxide-paths.txt\` is your zoxide database at backup time
   (restore entries with: zoxide add <path>).

Nothing outside your rc files was modified by bettercd.
__BCD_EOF__
    printf 'bettercd: backup saved → %s\n' "$_bcd_bdir" >&2
    return 0
}

# convenience: interactive fuzzy cd (needs zoxide + fzf), like zi
if command -v zoxide >/dev/null 2>&1; then
    cdi() {
        _bcd_pick="$(zoxide query -i -- "$@")" && cd "$_bcd_pick"
    }
fi
