#!/bin/sh
# shellcheck disable=SC3044,SC3054,SC2154,SC2164,SC2016,SC2059
#   SC3044/SC3054/SC2154: declare/functions[] are bash/zsh-only and always
#   guarded by $BASH_VERSION/$ZSH_VERSION checks. SC2164: one-line cd
#   delegates propagate their exit status by design. SC2016: literal hints.
#   SC2059: color vars in printf formats are ours, never user input.
# bettercd — a better cd: zoxide-aware, auto-mkdir, with undo.
# https://github.com/fire17/bettercd
#
# Source this file from your shell rc, AFTER any `zoxide init` line:
#   source /path/to/bettercd.sh
#
# Pure shell (bash/zsh, POSIX-leaning). No dependencies.
# zoxide and fzf are optional enhancers — bettercd composes with them
# if present and works fine without them.

BETTERCD_VERSION="0.8.1"

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

# zoxide's own doctor warns whenever anything redefines cd after `zoxide init`.
# That is exactly what bettercd does — deliberately, delegating faithfully to
# __zoxide_z — so silence that one false positive (unless the user set it).
if [ "$_BETTERCD_MODE" = "zoxide" ] && [ -z "${_ZO_DOCTOR+x}" ]; then
    _ZO_DOCTOR=0
    export _ZO_DOCTOR
fi

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

# nth wrapping token of a space-separated list (0-based index). Tokenizes by
# hand rather than via `for x in $list` — zsh does not word-split unquoted
# expansions, so that idiom would see the whole list as a single token.
__bettercd_nth() { # $1 list, $2 index → prints list[index % count]
    _bcd_nc=0; _bcd_nrest="$1"
    while _bcd_nrest="${_bcd_nrest# }"; [ -n "$_bcd_nrest" ]; do
        _bcd_ntok="${_bcd_nrest%% *}"
        _bcd_nrest="${_bcd_nrest#"$_bcd_ntok"}"
        _bcd_nc=$((_bcd_nc + 1))
    done
    [ "$_bcd_nc" -gt 0 ] || return 0
    _bcd_nwant=$(( $2 % _bcd_nc )); _bcd_nj=0; _bcd_nrest="$1"
    while _bcd_nrest="${_bcd_nrest# }"; [ -n "$_bcd_nrest" ]; do
        _bcd_ntok="${_bcd_nrest%% *}"
        _bcd_nrest="${_bcd_nrest#"$_bcd_ntok"}"
        [ "$_bcd_nj" = "$_bcd_nwant" ] && { printf '%s' "$_bcd_ntok"; return 0; }
        _bcd_nj=$((_bcd_nj + 1))
    done
}

# Damerau distance == 1 test (one add / remove / substitute / transpose).
# Strips the common prefix and suffix, then classifies the tiny remainder —
# cheap and pure-shell (dir names are short; this is never a hot path).
__bettercd_dist1() { # $1 typed, $2 candidate → 0 if exactly one edit apart
    _bcd_da="$1"; _bcd_db="$2"
    while [ -n "$_bcd_da" ] && [ -n "$_bcd_db" ]; do   # drop common prefix
        _bcd_fa=${_bcd_da#?}; _bcd_fa=${_bcd_da%"$_bcd_fa"}
        _bcd_fb=${_bcd_db#?}; _bcd_fb=${_bcd_db%"$_bcd_fb"}
        [ "$_bcd_fa" = "$_bcd_fb" ] || break
        _bcd_da=${_bcd_da#?}; _bcd_db=${_bcd_db#?}
    done
    while [ -n "$_bcd_da" ] && [ -n "$_bcd_db" ]; do   # drop common suffix
        _bcd_la=${_bcd_da%?}; _bcd_la=${_bcd_da#"$_bcd_la"}
        _bcd_lb=${_bcd_db%?}; _bcd_lb=${_bcd_db#"$_bcd_lb"}
        [ "$_bcd_la" = "$_bcd_lb" ] || break
        _bcd_da=${_bcd_da%?}; _bcd_db=${_bcd_db%?}
    done
    _bcd_na=${#_bcd_da}; _bcd_nb=${#_bcd_db}
    [ "$_bcd_na" = 1 ] && [ "$_bcd_nb" = 1 ] && return 0   # substitution
    [ "$_bcd_na" = 0 ] && [ "$_bcd_nb" = 1 ] && return 0   # insertion
    [ "$_bcd_na" = 1 ] && [ "$_bcd_nb" = 0 ] && return 0   # deletion
    if [ "$_bcd_na" = 2 ] && [ "$_bcd_nb" = 2 ]; then       # transposition
        _bcd_a1=${_bcd_da#?}; _bcd_a1=${_bcd_da%"$_bcd_a1"}
        _bcd_a2=${_bcd_da%?}; _bcd_a2=${_bcd_da#"$_bcd_a2"}
        _bcd_b1=${_bcd_db#?}; _bcd_b1=${_bcd_db%"$_bcd_b1"}
        _bcd_b2=${_bcd_db%?}; _bcd_b2=${_bcd_db#"$_bcd_b2"}
        [ "$_bcd_a1" = "$_bcd_b2" ] && [ "$_bcd_a2" = "$_bcd_b1" ] && return 0
    fi
    return 1
}

# Typo guard (F1). Runs only in the interactive, under-cwd, auto-create path,
# just before mkdir — offers a close-match sibling instead of a junk dir.
# Returns 0 → caller should create the target as usual (no match, or user
# chose "create"); 1 → caller returns $_bcd_guard_rc (we jumped or aborted).
__bettercd_typo_guard() { # $1 = normalized (absolute) target
    _bcd_guard_rc=1
    _bcd_gparent="${1%/*}"; [ -n "$_bcd_gparent" ] || _bcd_gparent="/"
    _bcd_gbase="${1##*/}"
    [ -n "$_bcd_gbase" ] || return 0
    _bcd_glow="$(printf '%s' "$_bcd_gbase" | tr '[:upper:]' '[:lower:]')"
    _bcd_matches=""; _bcd_mcount=0; _bcd_pfx=""; _bcd_pfxn=0
    # list sibling dirs via find, not a `*/` glob: an empty parent makes zsh
    # (nomatch on by default) ERROR on the glob instead of expanding to
    # nothing, which would abort the guard and block the create.
    _bcd_gents="$(find "$_bcd_gparent" -mindepth 1 -maxdepth 1 2>/dev/null)"
    while IFS= read -r _bcd_ge; do
        [ -d "$_bcd_ge" ] || continue   # empty lines fail -d too
        _bcd_gn="${_bcd_ge##*/}"
        [ "$_bcd_gn" = "$_bcd_gbase" ] && continue
        _bcd_gnl="$(printf '%s' "$_bcd_gn" | tr '[:upper:]' '[:lower:]')"
        if [ "$_bcd_gnl" = "$_bcd_glow" ] || __bettercd_dist1 "$_bcd_gbase" "$_bcd_gn"; then
            _bcd_matches="$_bcd_matches$_bcd_gn
"
            _bcd_mcount=$((_bcd_mcount + 1))
        fi
        case "$_bcd_gn" in
            "$_bcd_gbase"?*) _bcd_pfx="$_bcd_gn"; _bcd_pfxn=$((_bcd_pfxn + 1)) ;;
        esac
    done <<__BCD_EOF__
$_bcd_gents
__BCD_EOF__
    if [ "$_bcd_pfxn" = 1 ]; then           # add a UNIQUE prefix match, if new
        case "
$_bcd_matches" in
            *"
$_bcd_pfx
"*) ;;
            *) _bcd_matches="$_bcd_matches$_bcd_pfx
"; _bcd_mcount=$((_bcd_mcount + 1)) ;;
        esac
    fi
    [ "$_bcd_mcount" -gt 0 ] || return 0     # no close match → create as usual

    _bcd_first=""; _bcd_list=""; _bcd_shown=0
    while IFS= read -r _bcd_m; do
        [ -n "$_bcd_m" ] || continue
        [ -n "$_bcd_first" ] || _bcd_first="$_bcd_m"
        if [ "$_bcd_shown" -lt 4 ]; then
            _bcd_list="$_bcd_list $_bcd_m/"
            _bcd_shown=$((_bcd_shown + 1))
        fi
    done <<__BCD_EOF__
$_bcd_matches
__BCD_EOF__
    [ "$_bcd_mcount" -gt 1 ] && printf 'bettercd: did you mean one of:%s\n' "$_bcd_list" >&2
    printf 'bettercd: did you mean %s/ ? [Y=jump / c=create %s / n=abort] ' \
        "$_bcd_first" "$_bcd_gbase" >&2
    read -r _bcd_gans
    case "$_bcd_gans" in
        ''|y|Y|yes|YES)
            if [ "$_bcd_gparent" = "/" ]; then _bcd_jump="/$_bcd_first"
            else _bcd_jump="$_bcd_gparent/$_bcd_first"; fi
            __bettercd_delegate "$_bcd_jump" && __bettercd_clear_miss
            _bcd_guard_rc=$?
            return 1 ;;
        c|C)
            return 0 ;;
        *)
            __bettercd_clear_miss
            printf 'bettercd: aborted.\n' >&2
            _bcd_guard_rc=1
            return 1 ;;
    esac
}

# --- sparkle: animated inline "+" on the create-info line ---------------------
# Interactive terminals get a one-line announcement whose leading "+" keeps
# sparkling for ~2s AFTER the prompt is back (Claude-Code-style churn glyphs).
# The create only sets a pending flag; the precmd hook prints the line right
# before the prompt draws — after ALL command output — so its absolute row
# (CSI 6n cursor report) is exact. A detached animator then redraws that one
# cell around cursor save/restore, so typing is untouched, and the hooks kill
# it the moment anything would scroll the screen.
# Scripts / non-tty / BETTERCD_SPARKLE=0 keep the plain static messages.

# tty capable of the fancy stuff: real /dev/tty, non-dumb TERM, bash/zsh, UTF-8.
# Shared by the sparkle line and the magic cd - menu (which has its own toggle).
__bettercd_tty_ok() {
    [ -t 2 ] || return 1
    [ "${TERM-}" != dumb ] || return 1
    [ -n "${ZSH_VERSION-}${BASH_VERSION-}" ] || return 1
    case "${LC_ALL:-${LC_CTYPE:-${LANG-}}}" in
        *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;;
        *) return 1 ;;
    esac
    ( : </dev/tty ) 2>/dev/null
}

__bettercd_fancy() {
    [ "${BETTERCD_SPARKLE-1}" != 0 ] || return 1
    __bettercd_tty_ok
}

# Ask the terminal where the cursor is; sets _bcd_crow/_bcd_ccol. Any typed-
# ahead input the query swallows is pushed back into zsh's editor (print -z).
__bettercd_cursor_pos() {
    _bcd_ost="$(command stty -g </dev/tty 2>/dev/null)" || return 1
    [ -n "$_bcd_ost" ] || return 1
    command stty raw -echo min 0 time 5 </dev/tty 2>/dev/null || return 1
    printf '\033[6n' >/dev/tty
    _bcd_rep=""
    # shellcheck disable=SC3045,SC2034  # read -d: only reached in bash/zsh (fancy gate)
    IFS= read -r -d R _bcd_rep </dev/tty 2>/dev/null
    command stty "$_bcd_ost" </dev/tty 2>/dev/null
    _bcd_esc="$(printf '\033')"
    _bcd_pre="${_bcd_rep%%"$_bcd_esc"*}"
    if [ -n "$_bcd_pre" ] && [ -n "${ZSH_VERSION-}" ]; then
        print -z -- "$_bcd_pre" 2>/dev/null
    fi
    _bcd_rep="${_bcd_rep##*\[}"
    _bcd_crow="${_bcd_rep%%;*}"
    _bcd_ccol="${_bcd_rep##*;}"
    case "$_bcd_crow" in ''|*[!0-9]*) return 1 ;; esac
    case "$_bcd_ccol" in ''|*[!0-9]*) _bcd_ccol=1 ;; esac
    return 0
}

__bettercd_anim() { # $1 = absolute row of the glyph cell; writes to /dev/tty
    # Themeable frames (F3): BETTERCD_SPARKLE_GLYPHS / _COLORS override the
    # defaults; invalid or empty values fall back safely.
    _bcd_glyphs="${BETTERCD_SPARKLE_GLYPHS-✢ ✳ ✶ ✻ ✽ ✻ ✶ ✳}"
    [ -n "$_bcd_glyphs" ] || _bcd_glyphs='✢ ✳ ✶ ✻ ✽ ✻ ✶ ✳'
    _bcd_colors="${BETTERCD_SPARKLE_COLORS-213 219 177 225}"
    # valid = only digits and spaces, with at least one digit (glob-class test,
    # so it needs no word splitting — zsh-safe); anything else → fall back
    case "$_bcd_colors" in
        *[![:digit:][:space:]]*) _bcd_colors='213 219 177 225' ;;
        *[[:digit:]]*) ;;
        *) _bcd_colors='213 219 177 225' ;;
    esac
    _bcd_i=0
    while [ "$_bcd_i" -lt 16 ]; do   # 16 frames x 0.12s ≈ 2s
        _bcd_g="$(__bettercd_nth "$_bcd_glyphs" "$_bcd_i")"
        _bcd_c="$(__bettercd_nth "$_bcd_colors" "$_bcd_i")"
        # sleep first: the anchor pre-compensates the prompt's scroll,
        # so give the prompt one frame to actually draw
        command sleep 0.12
        printf '\0337\033[%s;1H\033[38;5;%sm%s\033[0m\0338' "$1" "$_bcd_c" "$_bcd_g"
        _bcd_i=$((_bcd_i + 1))
    done
    printf '\0337\033[%s;1H\033[1;32m+\033[0m\0338' "$1"
}

__bettercd_anim_kill() {
    [ -n "${_BETTERCD_ANIM_PID-}" ] || return 0
    # command: users override kill (e.g. kill-by-port wrappers) — bypass them
    command kill "$_BETTERCD_ANIM_PID" 2>/dev/null
    _BETTERCD_ANIM_PID=""
    return 0
}

__bettercd_sparkline() { # $1 = created target — the colored one-liner
    printf '\033[1;32m+\033[0m auto created & cd to \033[1;36m%s\033[0m \033[2m- if you did not mean this - press \033[0m\033[1m↑\033[0m\033[2m or run \033[0m\033[1mundo-cd\033[0m\033[2m to revert this action\033[0m\n' "$1" >&2
}

# History hint: push a synthetic `undo-cd` into THIS shell's in-memory history
# right after a create, so pressing ↑ at the fresh prompt offers the revert.
# Current shell only — undo state is session-local, so other shells' history
# files would offer an undo-cd that can't undo. BETTERCD_HISTORY_HINT=0 opts out.
__bettercd_history_hint() {
    [ "${BETTERCD_HISTORY_HINT-1}" != 0 ] || return 0
    if [ -n "${ZSH_VERSION-}" ]; then
        print -s -- undo-cd 2>/dev/null
    elif [ -n "${BASH_VERSION-}" ]; then
        history -s undo-cd 2>/dev/null
    fi
    return 0
}

# Runs right before every prompt. A pending create prints its line here —
# after all command output, so the glyph row can be computed exactly, even
# at the bottom of the screen. Any prompt after that means a scroll: kill.
__bettercd_anim_precmd() {
    # recent-places tracking (magic cd -): catches EVERY cwd change — our cd,
    # pushd, autocd. Hot path, so pure string ops, zero forks, no dedup/cap
    # here; the menu dedups + drops $PWD + caps at 8 lazily when it opens.
    if [ "$PWD" != "${_BETTERCD_LASTPWD-}" ]; then
        # remember this dir's inode while it still exists — inodes survive
        # same-filesystem renames/moves, which is what lets a later miss say
        # "moved, and here's where" instead of a bare error. `ls -di` is the
        # portable inode read (POSIX; no BSD-vs-GNU stat flags). One fork per
        # DIRECTORY CHANGE, never per prompt. (Windows/PS port: NTFS FileID.)
        _bcd_ino="$(command ls -di "$PWD" 2>/dev/null)"
        _bcd_ino="${_bcd_ino#"${_bcd_ino%%[0-9]*}"}"   # ltrim to first digit
        _bcd_ino="${_bcd_ino%%[!0-9]*}"                 # keep leading digits only
        [ -n "$_bcd_ino" ] && _BETTERCD_INOS="$_bcd_ino $PWD
${_BETTERCD_INOS-}"
        [ -n "${_BETTERCD_LASTPWD-}" ] && _BETTERCD_RECENT="$_BETTERCD_LASTPWD
${_BETTERCD_RECENT-}"
        _BETTERCD_LASTPWD="$PWD"
    fi
    __bettercd_anim_kill
    [ -n "${_BETTERCD_ANIM_PENDING-}" ] || return 0
    _bcd_t="$_BETTERCD_ANIM_PENDING"
    _BETTERCD_ANIM_PENDING=""
    if ! __bettercd_cursor_pos; then
        __bettercd_sparkline "$_bcd_t"   # no cursor report: static line, no anim
        __bettercd_history_hint
        return 0
    fi
    _bcd_start="$_bcd_crow"
    if [ "$_bcd_ccol" -gt 1 ]; then     # finish a partial output line first
        printf '\n' >&2
        _bcd_start=$((_bcd_start + 1))
    fi
    __bettercd_sparkline "$_bcd_t"
    __bettercd_history_hint
    _bcd_plain="+ auto created & cd to $_bcd_t - if you did not mean this - press X or run undo-cd to revert this action"
    _bcd_rows=$(( (${#_bcd_plain} - 1) / ${COLUMNS:-80} + 1 ))
    # ponytail: bash prompts assumed 1 line; zsh counts expanded PS1 lines
    _bcd_pl=1
    if [ -n "${ZSH_VERSION-}" ]; then
        # two-step: forces array context so ${#…} counts lines, not chars
        eval '_bcd_pla=("${(@f)${(%%)PS1}}"); _bcd_pl=${#_bcd_pla}; unset _bcd_pla' 2>/dev/null
    fi
    case "$_bcd_pl" in ''|*[!0-9]*) _bcd_pl=1 ;; esac
    _bcd_anchor="$_bcd_start"
    if [ "${LINES:-0}" -gt 0 ]; then
        _bcd_scr=$(( _bcd_start + _bcd_rows - LINES ))      # scroll printing the line causes
        [ "$_bcd_scr" -gt 0 ] || _bcd_scr=0
        _bcd_cur=$(( _bcd_start + _bcd_rows ))              # cursor row after the line
        [ "$_bcd_cur" -le "$LINES" ] || _bcd_cur="$LINES"
        _bcd_over=$(( _bcd_cur + _bcd_pl - 1 - LINES ))     # scroll the prompt will cause
        [ "$_bcd_over" -gt 0 ] || _bcd_over=0
        _bcd_anchor=$(( _bcd_start - _bcd_scr - _bcd_over ))
    fi
    [ "$_bcd_anchor" -ge 1 ] || return 0
    # detached via nested subshell: no job-control noise, no wait on exit
    _BETTERCD_ANIM_PID="$( ( __bettercd_anim "$_bcd_anchor" </dev/null >/dev/tty 2>/dev/null & printf '%s' $! ) )"
    return 0
}

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
        if __bettercd_fancy; then
            # announced by the precmd hook, after all command output
            _BETTERCD_ANIM_PENDING="$_bcd_target"
            return 0
        fi
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

# --- magic cd - : a sparkling dropdown of recent places ----------------------
# `cd -` twice (or ≥2 within a minute) opens a menu of where you've been; plain
# Enter picks $OLDPWD, so it stays === classic `cd -`. `cd --` opens it directly.
# Non-interactive shells and BETTERCD_MAGIC=0 keep the exact classic toggle.

# Validated magic window in seconds (default 300). One source of truth.
__bettercd_magic_window() {
    _bcd_mw="${BETTERCD_MAGIC_WINDOW:-300}"
    case "$_bcd_mw" in ''|*[!0-9]*) _bcd_mw=300 ;; esac
    printf '%s' "$_bcd_mw"
}

# Arm the magic window: remember this dash and stay magic until now+WINDOW.
# A known dir vanished (cd - target gone). Deleted or moved? Inodes answer:
# same-filesystem renames/moves keep the inode, so search nearby scopes for
# it — found means moved (and we know where), else "deleted or moved away".
# Cross-filesystem moves change inodes: honest fallback message, no guessing.
__bettercd_vanished() { # $1 = the missing dir; rc0 = relocated + cd'd there
    __bettercd_colors_v=""
    if [ -t 2 ] && [ -z "${NO_COLOR-}" ] && [ "${TERM-}" != dumb ]; then __bettercd_colors_v=1; fi
    _bcd_vino=""
    while IFS= read -r _bcd_vl; do
        case "$_bcd_vl" in
            *" $1") _bcd_vino="${_bcd_vl%% *}"; break ;;
        esac
    done <<__BCD_EOF__
${_BETTERCD_INOS-}
__BCD_EOF__
    _bcd_vnew=""
    if [ -n "$_bcd_vino" ]; then
        _bcd_vpar="${1%/*}"; [ -n "$_bcd_vpar" ] || _bcd_vpar="/"
        _bcd_vgp="${_bcd_vpar%/*}"; [ -n "$_bcd_vgp" ] || _bcd_vgp="/"
        _bcd_vnew="$(command find "$_bcd_vpar" -maxdepth 2 -inum "$_bcd_vino" -type d 2>/dev/null | head -1)"
        [ -n "$_bcd_vnew" ] || \
            _bcd_vnew="$(command find "$_bcd_vgp" -maxdepth 3 -inum "$_bcd_vino" -type d 2>/dev/null | head -1)"
    fi
    if [ -n "$_bcd_vnew" ] && [ "$_bcd_vnew" != "$1" ] && [ -d "$_bcd_vnew" ]; then
        if [ -n "$__bettercd_colors_v" ]; then
            printf '\033[38;5;213m✻\033[0m \033[2m%s is now\033[0m \033[1;36m%s\033[0m \033[2m— taking you there\033[0m\n' \
                "$(__bettercd_home_rel "$1")" "$(__bettercd_home_rel "$_bcd_vnew")" >&2
        else
            printf 'bettercd: %s is now %s — taking you there\n' "$1" "$_bcd_vnew" >&2
        fi
        __bettercd_delegate "$_bcd_vnew" && __bettercd_clear_miss
        return $?
    fi
    if [ -n "$__bettercd_colors_v" ]; then
        printf '\033[38;5;213m✻\033[0m \033[1;36m%s\033[0m \033[2mdoes not exist there anymore (deleted or moved away)\033[0m\n' \
            "$(__bettercd_home_rel "$1")" >&2
    else
        printf 'bettercd: %s does not exist there anymore (deleted or moved away)\n' "$1" >&2
    fi
    return 1
}

__bettercd_dash_arm() { # $1 = now (epoch secs)
    case "${1-}" in ''|*[!0-9]*) return 0 ;; esac
    _BETTERCD_LAST_DASH="$1"
    _BETTERCD_MAGIC_UNTIL=$(( $1 + $(__bettercd_magic_window) ))
}

# Decision helper (now as $1 so the suite can test it without a clock or a
# tty). Sets _bcd_dash_mode to classic|magic and updates _BETTERCD_LAST_DASH /
# _BETTERCD_MAGIC_UNTIL. Must run in the CURRENT shell (never via $(...)): the
# state it updates has to persist across cd - invocations. Auto-magic is
# OPT-IN: anything but BETTERCD_MAGIC=1 → always classic.
__bettercd_dash_mode() { # $1 = now → sets $_bcd_dash_mode
    if [ "${BETTERCD_MAGIC-0}" != 1 ]; then
        _BETTERCD_LAST_DASH="$1"; _bcd_dash_mode=classic; return 0
    fi
    # inside an active window → magic, and refresh the window
    if [ -n "${_BETTERCD_MAGIC_UNTIL-}" ] && [ "$1" -lt "$_BETTERCD_MAGIC_UNTIL" ]; then
        __bettercd_dash_arm "$1"; _bcd_dash_mode=magic; return 0
    fi
    # a prior dash within the last 60s → activate
    if [ -n "${_BETTERCD_LAST_DASH-}" ] && [ $(( $1 - _BETTERCD_LAST_DASH )) -le 60 ] \
       && [ $(( $1 - _BETTERCD_LAST_DASH )) -ge 0 ]; then
        __bettercd_dash_arm "$1"; _bcd_dash_mode=magic; return 0
    fi
    _BETTERCD_LAST_DASH="$1"; _bcd_dash_mode=classic; return 0
}

# Home-relative display: ~/foo for paths under $HOME.
__bettercd_home_rel() { # $1 path
    case "$1" in
        "$HOME")   printf '~' ;;
        "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
        *)         printf '%s' "$1" ;;
    esac
}

# Nth (0-based) non-empty line of a newline list.
__bettercd_nthline() { # $1 list, $2 index
    _bcd_tl_i=0
    while IFS= read -r _bcd_tl_l; do
        [ -n "$_bcd_tl_l" ] || continue
        [ "$_bcd_tl_i" = "$2" ] && { printf '%s' "$_bcd_tl_l"; return 0; }
        _bcd_tl_i=$((_bcd_tl_i + 1))
    done <<__BCD_EOF__
$1
__BCD_EOF__
}

# Draw the whole menu (header + rows) to /dev/tty. Raw mode ⇒ lines end \r\n.
# The selected row's ✻ cycles the sparkle palette by $4 for a little delight.
__bettercd_menu_draw() { # $1 list, $2 count, $3 selected, $4 frame
    _bcd_dc="$(__bettercd_nth '213 219 177 225' "$4")"
    printf '\033[38;5;213m✻\033[0m \033[2mrecent places  ↑↓ move · ⏎ cd · esc cancel\033[0m\033[K\r\n' >/dev/tty
    _bcd_di=0
    while IFS= read -r _bcd_dp; do
        [ -n "$_bcd_dp" ] || continue
        _bcd_dd="$(__bettercd_home_rel "$_bcd_dp")"
        if [ "$_bcd_di" = "$3" ]; then
            printf '\033[38;5;%sm✻\033[0m \033[1;36m%s\033[0m\033[K\r\n' "$_bcd_dc" "$_bcd_dd" >/dev/tty
        else
            printf '  \033[2m· %s\033[0m\033[K\r\n' "$_bcd_dd" >/dev/tty
        fi
        _bcd_di=$((_bcd_di + 1))
    done <<__BCD_EOF__
$1
__BCD_EOF__
}

# The interactive loop: raw single-byte input, redraw in place, clean erase.
# stty is restored before EVERY return path (trap-free by design).
__bettercd_menu_loop() { # $1 list, $2 count
    _bcd_ml_list="$1"; _bcd_ml_n="$2"; _bcd_ml_sel=0; _bcd_ml_frame=0
    _bcd_ml_lines=$((_bcd_ml_n + 1))
    _bcd_ml_st="$(command stty -g </dev/tty 2>/dev/null)"
    [ -n "$_bcd_ml_st" ] || { __bettercd_delegate - && __bettercd_clear_miss; return $?; }
    command stty raw -echo </dev/tty 2>/dev/null
    __bettercd_menu_draw "$_bcd_ml_list" "$_bcd_ml_n" "$_bcd_ml_sel" "$_bcd_ml_frame"

    _bcd_ml_esc="$(printf '\033')"; _bcd_ml_cr="$(printf '\r')"
    _bcd_ml_etx="$(printf '\003')"; _bcd_ml_act=""
    while :; do
        _bcd_ml_key="$(dd bs=1 count=1 2>/dev/null </dev/tty)"
        _bcd_ml_move=""
        case "$_bcd_ml_key" in
            "$_bcd_ml_esc")
                command stty min 0 time 2 </dev/tty 2>/dev/null
                _bcd_ml_seq="$(dd bs=1 count=2 2>/dev/null </dev/tty)"
                command stty raw -echo </dev/tty 2>/dev/null
                case "$_bcd_ml_seq" in
                    '[A'|'OA') _bcd_ml_move=up ;;
                    '[B'|'OB') _bcd_ml_move=down ;;
                    '')        _bcd_ml_act=cancel ;;   # bare ESC
                    *) ;;
                esac ;;
            k|K) _bcd_ml_move=up ;;
            j|J) _bcd_ml_move=down ;;
            "$_bcd_ml_cr") _bcd_ml_act=select ;;
            ''|q|Q|"$_bcd_ml_etx") _bcd_ml_act=cancel ;;   # EOF / q / Ctrl-C
            [1-8])
                if [ "$_bcd_ml_key" -le "$_bcd_ml_n" ]; then
                    _bcd_ml_sel=$((_bcd_ml_key - 1)); _bcd_ml_act=select
                fi ;;
            *) ;;
        esac
        if [ "$_bcd_ml_move" = up ]; then
            _bcd_ml_sel=$(( (_bcd_ml_sel - 1 + _bcd_ml_n) % _bcd_ml_n ))
            _bcd_ml_frame=$((_bcd_ml_frame + 1))
        elif [ "$_bcd_ml_move" = down ]; then
            _bcd_ml_sel=$(( (_bcd_ml_sel + 1) % _bcd_ml_n ))
            _bcd_ml_frame=$((_bcd_ml_frame + 1))
        fi
        [ -n "$_bcd_ml_act" ] && break
        printf '\033[%dA' "$_bcd_ml_lines" >/dev/tty
        __bettercd_menu_draw "$_bcd_ml_list" "$_bcd_ml_n" "$_bcd_ml_sel" "$_bcd_ml_frame"
    done

    printf '\033[%dA\033[J' "$_bcd_ml_lines" >/dev/tty   # erase the menu
    command stty "$_bcd_ml_st" </dev/tty 2>/dev/null      # restore BEFORE acting
    if [ "$_bcd_ml_act" = select ]; then
        _bcd_ml_pick="$(__bettercd_nthline "$_bcd_ml_list" "$_bcd_ml_sel")"
        if [ -n "$_bcd_ml_pick" ]; then
            __bettercd_delegate "$_bcd_ml_pick" && __bettercd_clear_miss
            _bcd_ml_rc=$?
            printf '\033[2m✻ cd %s\033[0m\n' "$(__bettercd_home_rel "$_bcd_ml_pick")" >/dev/tty
            return "$_bcd_ml_rc"
        fi
    fi
    return 1   # cancel
}

# One-time backlog seed for the dropdown: places you went BEFORE this session
# started using bettercd. Best source is zoxide's db (real visited dirs,
# absolute, frecency-ordered); fallback parses zsh/bash history for `cd`
# commands with absolute or ~ targets ONLY — relative entries (`cd test`)
# are honestly unresolvable: the cwd they were typed in is unknown. Runs
# lazily at first menu build, never at source time (startup stays instant).
__bettercd_seed_recent() {
    [ -n "${_BETTERCD_SEEDED-}" ] && return 0
    _BETTERCD_SEEDED=1
    _bcd_sd=""
    if command -v zoxide >/dev/null 2>&1; then
        _bcd_sd="$(command zoxide query -l 2>/dev/null | head -20)"
    fi
    if [ -z "$_bcd_sd" ]; then
        for _bcd_shf in "${HISTFILE-}" "$HOME/.zsh_history" "$HOME/.bash_history"; do
            [ -f "$_bcd_shf" ] || continue   # empty var fails -f too
            # strip zsh extended-history prefixes; keep cd /abs and cd ~/…;
            # newest first (awk reverse — tac/tail -r aren't both portable)
            _bcd_sd="$(sed -e 's/^: [0-9]*:[0-9]*;//' "$_bcd_shf" 2>/dev/null \
                | grep -E '^[[:space:]]*cd[[:space:]]+["'\'']?(/|~)' \
                | sed -e 's/^[[:space:]]*cd[[:space:]]*//' -e 's/^["'\'']//' -e 's/["'\'']$//' \
                      -e "s|^~|$HOME|" \
                | tail -50 \
                | awk '{a[NR]=$0} END{for(i=NR;i>=1;i--)print a[i]}')"
            [ -n "$_bcd_sd" ] && break
        done
    fi
    [ -n "$_bcd_sd" ] || return 0
    # append AFTER live-session recents: the backlog never outranks what the
    # user actually did just now; menu-time -d checks drop dead entries
    _BETTERCD_RECENT="${_BETTERCD_RECENT-}
$_bcd_sd"
    return 0
}

# Entry point: build the list (OLDPWD first + deduped recent, cap 8), or fall
# back to a silent classic toggle when there's nothing worth a menu.
__bettercd_magic_menu() { # $1 = "forced" when the user explicitly asked (cd --)
    __bettercd_tty_ok || { __bettercd_delegate - && __bettercd_clear_miss; return $?; }
    __bettercd_seed_recent
    _bcd_mm_list=""; _bcd_mm_n=0
    if [ -n "${OLDPWD-}" ] && [ -d "$OLDPWD" ]; then
        _bcd_mm_list="$OLDPWD
"; _bcd_mm_n=1
    fi
    while IFS= read -r _bcd_mm_r; do
        [ "$_bcd_mm_n" -lt 8 ] || break
        [ -n "$_bcd_mm_r" ] || continue
        [ "$_bcd_mm_r" = "$PWD" ] && continue
        [ -d "$_bcd_mm_r" ] || continue
        case "
$_bcd_mm_list" in *"
$_bcd_mm_r
"*) continue ;; esac
        _bcd_mm_list="$_bcd_mm_list$_bcd_mm_r
"; _bcd_mm_n=$((_bcd_mm_n + 1))
    done <<__BCD_EOF__
${_BETTERCD_RECENT-}
__BCD_EOF__
    if [ "${1-}" = forced ]; then
        # explicit ask (cd --): always show what we have; nothing at all →
        # say so prettily instead of silently doing something else
        if [ "$_bcd_mm_n" -eq 0 ]; then
            printf '\033[38;5;213m✻\033[0m \033[2mno recent places yet — move around a little first\033[0m\n' >&2
            return 1
        fi
    elif [ "$_bcd_mm_n" -le 1 ]; then        # auto mode, just OLDPWD/empty → classic
        __bettercd_delegate - && __bettercd_clear_miss
        return $?
    fi
    __bettercd_menu_loop "$_bcd_mm_list" "$_bcd_mm_n"
}

# --- the cd wrapper ----------------------------------------------------------
cd() {
    # fast passthroughs: no args, multiple args, flags, "-", dir-stack refs
    if [ "$#" -ne 1 ]; then
        __bettercd_delegate "$@" && __bettercd_clear_miss
        return $?
    fi
    case "$1" in
        '' )
            __bettercd_delegate "$@" && __bettercd_clear_miss
            return $? ;;
        - )
            # vanished toggle target: pretty in-brand message (and auto-follow
            # a same-filesystem move) instead of the delegate's raw error.
            # Interactive only — scripts keep the stock failure exactly.
            if [ -n "${OLDPWD-}" ] && [ ! -d "$OLDPWD" ] && __bettercd_interactive; then
                __bettercd_vanished "$OLDPWD"
                return $?
            fi
            # magic cd -: two in a row (or an active window) → dropdown.
            # Non-interactive OR BETTERCD_MAGIC=0 → exact classic toggle.
            _bcd_now="$(date +%s 2>/dev/null)"   # external date OK: rare path
            case "$_bcd_now" in
                ''|*[!0-9]*) ;;                  # no clock → classic
                *)
                    # auto-magic is OPT-IN (bettercd magic on); default keeps
                    # cd - exactly classic — cd -- is the dropdown's home
                    if [ "${BETTERCD_MAGIC-0}" = 1 ] && __bettercd_interactive; then
                        __bettercd_dash_mode "$_bcd_now"
                        if [ "$_bcd_dash_mode" = magic ]; then
                            __bettercd_magic_menu
                            return $?
                        fi
                    fi ;;
            esac
            __bettercd_delegate "$@" && __bettercd_clear_miss
            return $? ;;
        -- )
            # `cd --` opens the dropdown directly — explicit invocation is
            # consent, independent of the auto-magic setting.
            if __bettercd_interactive; then
                __bettercd_dash_arm "$(date +%s 2>/dev/null)"
                __bettercd_magic_menu forced
                return $?
            fi
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

    # editor / stack-trace paste (F2): foo.py:42 or foo.py:42:7 — the raw
    # target is missing; strip one or two trailing :<digits> groups and, if
    # what's left EXISTS, go there (dir → enter it, file → its parent). A dir
    # literally named foo:42 is unaffected: we only act when the stripped
    # path exists, else we fall through untouched with the original arg.
    case "$1" in
        *:[0-9]*)
            _bcd_ep="$1"; _bcd_epn=0
            while [ "$_bcd_epn" -lt 2 ]; do
                _bcd_tail="${_bcd_ep##*:}"
                case "$_bcd_ep" in *:*) ;; *) break ;; esac
                case "$_bcd_tail" in ''|*[!0-9]*) break ;; esac
                _bcd_ep="${_bcd_ep%:*}"
                _bcd_epn=$((_bcd_epn + 1))
            done
            if [ "$_bcd_epn" -gt 0 ] && [ -e "$_bcd_ep" ]; then
                if [ -d "$_bcd_ep" ]; then
                    _bcd_eres="$_bcd_ep"
                else
                    _bcd_eres="$(dirname -- "$_bcd_ep")"
                fi
                printf 'bettercd: %s → cd %s\n' "$1" "$_bcd_eres" >&2
                __bettercd_delegate "$_bcd_eres" && __bettercd_clear_miss
                return $?
            fi ;;
    esac

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
            # typo guard (F1): interactive only, never for trailing-slash
            # (explicit create intent), disablable via BETTERCD_TYPO_GUARD=0.
            # Non-interactive shells keep today's behavior exactly (CI safety).
            if [ -z "$_bcd_force_create" ] && [ "${BETTERCD_TYPO_GUARD-1}" != 0 ] \
               && __bettercd_interactive; then
                if ! __bettercd_typo_guard "$_bcd_norm"; then
                    return "$_bcd_guard_rc"
                fi
            fi
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

# undo-cd — what the sparkle line tells you to run (hyphenated names need
# bash/zsh, hence the eval; plain sh keeps `bettercd undo`; bash running AS
# sh — posix mode, e.g. macOS /bin/sh — rejects hyphens, so skip there too)
if [ -n "${ZSH_VERSION-}${BASH_VERSION-}" ]; then
    # shellcheck disable=SC3028  # SHELLOPTS: bash-only, harmlessly empty elsewhere
    case ":${SHELLOPTS-}:" in
        *:posix:*) ;;
        *) eval 'undo-cd() { bettercd undo; }' ;;
    esac
fi

# prompt hooks that stop the sparkle animator once the screen scrolls
if [ -n "${ZSH_VERSION-}" ]; then
    eval 'typeset -ga precmd_functions preexec_functions
    (( ${precmd_functions[(Ie)__bettercd_anim_precmd]} )) ||
        precmd_functions+=(__bettercd_anim_precmd)
    (( ${preexec_functions[(Ie)__bettercd_anim_kill]} )) ||
        preexec_functions+=(__bettercd_anim_kill)'
elif [ -n "${BASH_VERSION-}" ]; then
    case "$(declare -p PROMPT_COMMAND 2>/dev/null)" in
        "declare -a"*) eval 'case " ${PROMPT_COMMAND[*]} " in
                *__bettercd_anim_precmd*) ;;
                *) PROMPT_COMMAND+=(__bettercd_anim_precmd) ;;
            esac' ;;
        *) case ";${PROMPT_COMMAND-};" in
               *__bettercd_anim_precmd*) ;;
               *) PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND;}__bettercd_anim_precmd" ;;
           esac ;;
    esac
fi

# --- cd-typos: cd.. and friends ------------------------------------------------
# `cd..` is its own command WORD, so the cd function never sees it. Plain
# aliases translate the classic dot-typos (each extra dot = one more level).
# Why not a command-not-found hook: shells run that handler in a SUBSHELL, so
# its cd can never move the parent — verified live; aliases are what works.
# BETTERCD_CD_TYPOS=0 before sourcing disables. (bash scripts are unaffected
# either way: non-interactive bash never expands aliases.)
if [ -n "${ZSH_VERSION-}${BASH_VERSION-}" ] && [ "${BETTERCD_CD_TYPOS-1}" != 0 ]; then
    alias cd..='cd ..'
    alias cd...='cd ../..'
    alias cd....='cd ../../..'
    alias cd.....='cd ../../../..'
fi

# --- the bettercd command ----------------------------------------------------
bettercd() {
    case "${1-}" in
        undo)    __bettercd_undo ;;
        doctor)  shift; __bettercd_doctor "$@" ;;
        backup)  __bettercd_backup ;;
        magic)   shift; __bettercd_magic_cmd "$@" ;;
        status)  __bettercd_status ;;
        version|--version|-v) printf 'bettercd %s\n' "$BETTERCD_VERSION" ;;
        help|--help|-h|'')    __bettercd_help ;;
        *) printf 'bettercd: unknown command: %s (try: bettercd help)\n' "$1" >&2
           return 1 ;;
    esac
}

__bettercd_help() {
    # colors only on a tty, honoring NO_COLOR; plain text everywhere else
    if [ -t 1 ] && [ -z "${NO_COLOR-}" ] && [ "${TERM-}" != dumb ]; then
        _bh_T='\033[1;33m' _bh_S='\033[1;34m' _bh_C='\033[1;36m' _bh_G='\033[32m' _bh_D='\033[2m' _bh_R='\033[0m'
    else
        _bh_T='' _bh_S='' _bh_C='' _bh_G='' _bh_D='' _bh_R=''
    fi
    printf "\n  ${_bh_T}✻ bettercd ${BETTERCD_VERSION}${_bh_R} ${_bh_D}— a better cd: zoxide-aware, auto-mkdir, with undo${_bh_R}\n\n"
    printf "  ${_bh_S}USAGE${_bh_R}\n"
    printf "    ${_bh_C}%-22s${_bh_R} ${_bh_D}%s${_bh_R}\n" \
        "cd <existing>"  "plain cd (zoxide-aware, ~25µs, zero magic)" \
        "cd <missing>"   "under cwd → mkdir -p + cd, ✻ sparkle + undo hint" \
        ""               "elsewhere → fails once; repeat → [y/N] create" \
        "cd <missing>/"  "trailing slash: always create (skips fuzzy jump)" \
        "cd <typo>"      "close-match sibling? → did-you-mean before mkdir" \
        "cd <file>:42:7" "editor/stack-trace paste → cd to the file's dir" \
        "cd <file>"      "jump to the file's parent directory" \
        "cd -"           "classic toggle (magic on: twice → ✻ dropdown)" \
        "cd --"          "always open the ✻ recent-places dropdown" \
        "builtin cd -"   "always the classic toggle (bypasses bettercd)"
    printf "\n  ${_bh_S}COMMANDS${_bh_R}\n"
    printf "    ${_bh_C}%-22s${_bh_R} ${_bh_D}%s${_bh_R}\n" \
        "undo-cd"          "go back + remove what the last cd created" \
        "bettercd undo"    "same thing, spelled out (rmdir-only, never rm)" \
        "bettercd doctor"  "check zoxide / fzf / load order (--fix installs)" \
        "bettercd backup"  "snapshot your cd paradigm + RESTORE.md" \
        "bettercd status"  "mode, pending undo, version" \
        "bettercd magic"   "on|off|status|window <min> — the cd - dropdown" \
        "cd - (×2)"        "sparkling dropdown of recent places (cd -- forces it)" \
        "cdi <query>"      "interactive fuzzy cd (zoxide + fzf)"
    printf "\n  ${_bh_S}ENV${_bh_R}\n"
    printf "    ${_bh_C}%-25s${_bh_R} ${_bh_D}%s${_bh_R}\n" \
        "BETTERCD_AUTO_CREATE=0" "disable auto-create" \
        "BETTERCD_QUIET=1"       "suppress hints" \
        "BETTERCD_TYPO_GUARD=0"  "disable the did-you-mean typo guard" \
        "BETTERCD_SPARKLE=0"     "disable the animated create line" \
        "BETTERCD_HISTORY_HINT=0" "don't push undo-cd into history after a create" \
        "BETTERCD_SPARKLE_GLYPHS" "space-separated sparkle glyph frames" \
        "BETTERCD_SPARKLE_COLORS" "space-separated 256-color codes" \
        "BETTERCD_MAGIC=1"        "opt-in: cd - twice also opens the dropdown" \
        "BETTERCD_MAGIC_WINDOW=600" "seconds the dropdown stays armed (default 300)"
    printf "\n  ${_bh_S}EXAMPLE${_bh_R}\n"
    printf "    ${_bh_G}\$ cd projects/newapp/src${_bh_R}       ${_bh_D}# doesn't exist yet — now it does, you're in it${_bh_R}\n"
    printf "    ${_bh_G}\$ undo-cd${_bh_R}                      ${_bh_D}# changed your mind — back + cleaned up${_bh_R}\n"
    printf "\n  ${_bh_D}https://github.com/fire17/bettercd${_bh_R}\n\n"
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
    if __bettercd_fancy; then
        printf '\033[1;33m↩\033[0m back in \033[1;36m%s\033[0m \033[2m-\033[0m removed \033[1;32m%s\033[0m dir(s)' "$PWD" "$_bcd_removed" >&2
        [ -n "$_bcd_kept" ] && printf '\033[2m; kept (not empty):\033[0m\033[1;33m%s\033[0m' "$_bcd_kept" >&2
    else
        printf 'bettercd: back in %s — removed %s dir(s)' "$PWD" "$_bcd_removed" >&2
        [ -n "$_bcd_kept" ] && printf '; kept (not empty):%s' "$_bcd_kept" >&2
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

# bettercd magic on|off|status|window <minutes> — bettercd is a function, so a
# plain assignment sets the var in the CURRENT shell. Export in your rc to
# persist:  export BETTERCD_MAGIC=0   /   export BETTERCD_MAGIC_WINDOW=600
__bettercd_magic_cmd() {
    case "${1-status}" in
        on)  BETTERCD_MAGIC=1; printf 'bettercd: magic cd - is ON (auto)\n' ;;
        off) BETTERCD_MAGIC=0; printf 'bettercd: magic cd - is OFF\n' ;;
        window)
            case "${2-}" in
                ''|*[!0-9]*)
                    printf 'bettercd: magic window needs whole minutes, e.g. bettercd magic window 10\n' >&2
                    return 1 ;;
                *)
                    BETTERCD_MAGIC_WINDOW=$(( $2 * 60 ))
                    printf 'bettercd: magic window = %s min (%ss)\n' "$2" "$BETTERCD_MAGIC_WINDOW" ;;
            esac ;;
        status) __bettercd_magic_status ;;
        *) printf 'bettercd: magic {on|off|status|window <minutes>}\n' >&2; return 1 ;;
    esac
}

__bettercd_magic_status() {
    _bcd_gs_win="$(__bettercd_magic_window)"
    printf 'bettercd magic cd -\n'
    printf '  mode:          %s\n' "$([ "${BETTERCD_MAGIC-0}" = 1 ] && echo auto || echo 'off (default) — cd - classic; cd -- opens the dropdown')"
    printf '  window:        %ss (%s min)\n' "$_bcd_gs_win" "$(( _bcd_gs_win / 60 ))"
    _bcd_gs_now="$(date +%s 2>/dev/null)"
    case "$_bcd_gs_now" in
        ''|*[!0-9]*) printf '  active:        unknown (no clock)\n' ;;
        *)
            if [ -n "${_BETTERCD_MAGIC_UNTIL-}" ] && [ "$_bcd_gs_now" -lt "$_BETTERCD_MAGIC_UNTIL" ]; then
                printf '  active:        %ss left\n' "$(( _BETTERCD_MAGIC_UNTIL - _bcd_gs_now ))"
            else
                printf '  active:        not active\n'
            fi ;;
    esac
    _bcd_gs_c=0
    while IFS= read -r _bcd_gs_l; do
        [ -n "$_bcd_gs_l" ] && _bcd_gs_c=$((_bcd_gs_c + 1))
    done <<__BCD_EOF__
${_BETTERCD_RECENT-}
__BCD_EOF__
    printf '  recent places: %s\n' "$_bcd_gs_c"
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
