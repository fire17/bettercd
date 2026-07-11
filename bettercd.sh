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

BETTERCD_VERSION="0.12.0-dev"

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

# Seamless autoreload (interactive shells): remember where we were sourced
# from and stamp the load. Every cd does a ZERO-FORK freshness check — builtin
# `[ file -nt file ]` (one stat syscall) + a builtin read of the stamp — and
# re-sources this file when it changed, then re-runs the cd with the new code.
# BETTERCD_AUTORELOAD=0 disables; scripts never autoreload (deterministic).
_BETTERCD_SRC=""
if [ -n "${ZSH_VERSION-}" ]; then
    eval '_BETTERCD_SRC="${${(%):-%x}:A}"' 2>/dev/null
elif [ -n "${BASH_VERSION-}" ]; then
    # shellcheck disable=SC3028  # guarded bash-only
    _BETTERCD_SRC="${BASH_SOURCE[0]-}"
    case "$_BETTERCD_SRC" in
        ''|/*) ;;
        *) _BETTERCD_SRC="$(cd "$(dirname "$_BETTERCD_SRC")" 2>/dev/null && pwd)/${_BETTERCD_SRC##*/}" ;;
    esac
fi
[ -n "${ZSH_VERSION-}" ] && eval 'zmodload zsh/datetime 2>/dev/null'
command mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/bettercd" 2>/dev/null
_BETTERCD_STAMP="${XDG_CONFIG_HOME:-$HOME/.config}/bettercd/.loaded"
if [ -n "$_BETTERCD_SRC" ] && [ -f "$_BETTERCD_SRC" ]; then
    command mkdir -p "${_BETTERCD_STAMP%/*}" 2>/dev/null
    _bcd_srcm="$(command ls -ldT "$_BETTERCD_SRC" 2>/dev/null || command ls -ld "$_BETTERCD_SRC" 2>/dev/null)"
    _BETTERCD_LOADED="$BETTERCD_VERSION ${_bcd_srcm#* }"
    printf '%s\n' "$_BETTERCD_LOADED" > "$_BETTERCD_STAMP.tmp" 2>/dev/null && \
        command mv -f "$_BETTERCD_STAMP.tmp" "$_BETTERCD_STAMP" 2>/dev/null
    unset _bcd_srcm
fi

__bettercd_reload_check() { # rc0 = reloaded (caller should re-dispatch)
    [ "${BETTERCD_AUTORELOAD-1}" != 0 ] || return 1
    [ -n "$_BETTERCD_SRC" ] && [ -n "${_BETTERCD_LOADED-}" ] || return 1
    _bcd_rl=""
    if [ "$_BETTERCD_SRC" -nt "$_BETTERCD_STAMP" ]; then
        _bcd_rl=1                       # file edited since ANY shell loaded it
    else
        _bcd_rlc=""
        IFS= read -r _bcd_rlc < "$_BETTERCD_STAMP" 2>/dev/null
        [ -n "$_bcd_rlc" ] && [ "$_bcd_rlc" != "$_BETTERCD_LOADED" ] && _bcd_rl=1
    fi                                   # or another shell loaded a newer one
    [ -n "$_bcd_rl" ] || return 1
    # shellcheck disable=SC1090
    if . "$_BETTERCD_SRC" 2>/dev/null; then
        # W5: defer the notice to the next precmd, which centers it and spawns a
        # self-eraser (a raw print here would land mid-command, uncentered, and
        # never clear). Non-tty keeps a plain immediate line, no eraser.
        if [ -t 2 ] && [ -z "${NO_COLOR-}" ] && [ "${TERM-}" != dumb ]; then
            _BETTERCD_UPD_PENDING="$BETTERCD_VERSION"
        elif [ -t 2 ]; then
            printf 'bettercd auto-updated to %s\n' "$BETTERCD_VERSION" >&2
        fi
        return 0
    fi
    return 1
}

# control chars, computed once at source time (menus build frames fork-free)
_BETTERCD_ESC="$(printf '\033')"
_BETTERCD_CR="$(printf '\r')"
_BETTERCD_TAB="$(printf '\t')"
# ellipsis built via printf (not a source literal): non-interactive bash mangles
# multibyte literals concatenated into a var, but a printf-built var is safe.
_BETTERCD_ELL="$(printf '\342\200\246')"
_BETTERCD_MAG="$(printf '\342\214\225')"   # ⌕ — fallback query marker (W1')
_BETTERCD_GS="$(printf '\035')"            # GS — W7 query-stack level delimiter (never in a path)
# sort-direction arrows, printf-built for the same reason: bash mangles a
# multibyte LITERAL concatenated into a var, but a printf-built var is safe.
_BETTERCD_UARR="$(printf '\342\206\221')"   # ↑
_BETTERCD_DARR="$(printf '\342\206\223')"   # ↓

# builtin single-byte tty readers — no dd fork, no stty juggling per key.
# $1 = timeout in seconds ('' = block). Sets _bcd_key ('' on timeout/EOF).
if [ -n "${ZSH_VERSION-}" ]; then
    eval '__bettercd_readkey() {
        _bcd_key=""
        if [ -n "${1-}" ]; then
            read -t "$1" -k 1 -u 0 _bcd_key </dev/tty 2>/dev/null || _bcd_key=""
        else
            read -k 1 -u 0 _bcd_key </dev/tty 2>/dev/null || _bcd_key=""
        fi
    }'
elif [ -n "${BASH_VERSION-}" ]; then
    # bash < 4 rejects fractional read -t: fall back to dd + stty timeouts
    # there (menu still works, just costs a fork on escape tails)
    # shellcheck disable=SC3028  # BASH_VERSINFO: guarded bash-only branch
    if [ "${BASH_VERSINFO:-3}" -ge 4 ] 2>/dev/null; then
        eval '__bettercd_readkey() {
            _bcd_key=""
            if [ -n "${1-}" ]; then
                IFS= read -rs -t "$1" -n 1 _bcd_key </dev/tty 2>/dev/null || _bcd_key=""
            else
                IFS= read -rs -n 1 _bcd_key </dev/tty 2>/dev/null || _bcd_key=""
            fi
        }'
    else
        __bettercd_readkey() {
            _bcd_key=""
            if [ -n "${1-}" ]; then
                command stty min 0 time 2 </dev/tty 2>/dev/null
                _bcd_key="$(dd bs=1 count=1 2>/dev/null </dev/tty)"
                command stty raw -echo min 1 time 0 </dev/tty 2>/dev/null
            else
                _bcd_key="$(dd bs=1 count=1 2>/dev/null </dev/tty)"
            fi
        }
    fi
fi

# W1' — display width of the current prompt's LAST physical line (zsh only), so
# the dropdown can park the typed query directly onto the user's REAL command
# line ("cd -- <query>"). Sets _bcd_pw (columns) or '' on any failure / non-zsh,
# which makes the menu fall back to the on-frame ⌕ echo. All zsh-only syntax is
# eval-guarded so dash/bash still parse this file. Runs ONCE per menu open (the
# lone sed fork lives here, never in the keystroke loop).
__bettercd_prompt_width() {
    _bcd_pw=""
    [ -n "${ZSH_VERSION-}" ] || return 0
    eval '_bcd_pwx="${(%%)PS1-}"' 2>/dev/null || return 0
    [ -n "${_bcd_pwx-}" ] || return 0
    case "$_bcd_pwx" in *"
"*) _bcd_pwx="${_bcd_pwx##*"
"}" ;; esac
    _bcd_pwx="$(printf '%s' "$_bcd_pwx" | LC_ALL=C command sed 's/'"$(printf '\033')"'\[[0-9;?]*[a-zA-Z]//g' 2>/dev/null)"
    eval '_bcd_pw=${(m)#_bcd_pwx}' 2>/dev/null || _bcd_pw=""
    case "${_bcd_pw:-x}" in ''|*[!0-9]*) _bcd_pw="" ;; esac
}

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
    # W5: also reap the auto-update toast eraser — if a new prompt or command
    # arrives before its 2s timer, kill it so it can never erase the wrong line
    # (the toast just stays in scrollback, like any other message).
    if [ -n "${_BETTERCD_TOAST_PID-}" ]; then
        command kill "$_BETTERCD_TOAST_PID" 2>/dev/null
        _BETTERCD_TOAST_PID=""
    fi
    [ -n "${_BETTERCD_ANIM_PID-}" ] || return 0
    # command: users override kill (e.g. kill-by-port wrappers) — bypass them
    command kill "$_BETTERCD_ANIM_PID" 2>/dev/null
    _BETTERCD_ANIM_PID=""
    return 0
}

# W5: the auto-update toast eraser — a detached one-shot that, 2s after the
# centered "✻ bettercd auto-updated to <ver>" toast prints, clears that exact
# row in place (ESC7 save · jump · ESC[2K · ESC8 restore) so it never disturbs
# the live prompt. Registered with __bettercd_anim_kill, so any earlier prompt
# or command cancels it. $1 = absolute row of the toast.
__bettercd_toast_erase() { # $1 = row
    command sleep 2
    printf '\0337\033[%s;1H\033[2K\0338' "$1" >/dev/tty
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
        # visit stamp (for the dropdown's "visited" column): epoch via builtin
        # where the shell has one (zsh zsh/datetime EPOCHSECONDS, bash>=5);
        # else one date fork — only ever on a DIRECTORY CHANGE, never a prompt
        # shellcheck disable=SC3028  # EPOCHSECONDS: zsh(datetime)/bash5 builtin; empty elsewhere
        _bcd_vnow="${EPOCHSECONDS-}"
        [ -n "$_bcd_vnow" ] || _bcd_vnow="$(date +%s 2>/dev/null)"
        case "$_bcd_vnow" in *[!0-9]*|'') ;; *)
            printf '%s %s\n' "$_bcd_vnow" "$PWD" >> "${XDG_CONFIG_HOME:-$HOME/.config}/bettercd/visits" 2>/dev/null
        esac
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
    # W5: a pending auto-update notice prints here — CENTERED on its own row —
    # then a detached eraser clears it after 2s (registered with the kill hook
    # above, so a new prompt/command cancels it first). Printed before the
    # create sparkline when both pend; each takes its own CPR anchor.
    if [ -n "${_BETTERCD_UPD_PENDING-}" ]; then
        _bcd_uv="$_BETTERCD_UPD_PENDING"; _BETTERCD_UPD_PENDING=""
        _bcd_umsg="bettercd auto-updated to $_bcd_uv"
        _bcd_uvis=$(( ${#_bcd_umsg} + 2 ))            # + "✻ " (2 display columns)
        _bcd_ucol=$(( (${COLUMNS:-80} - _bcd_uvis) / 2 + 1 ))
        [ "$_bcd_ucol" -ge 1 ] || _bcd_ucol=1
        if __bettercd_cursor_pos; then
            _bcd_urow="$_bcd_crow"
            [ "$_bcd_ccol" -gt 1 ] && { printf '\n' >&2; _bcd_urow=$((_bcd_urow + 1)); }
            printf '\033[%dG\033[38;5;213m✻\033[0m \033[2m%s\033[0m\n' "$_bcd_ucol" "$_bcd_umsg" >&2
            _BETTERCD_TOAST_PID="$( ( __bettercd_toast_erase "$_bcd_urow" </dev/null >/dev/tty 2>/dev/null & printf '%s' $! ) )"
        else
            printf '\033[38;5;213m✻\033[0m \033[2m%s\033[0m\n' "$_bcd_umsg" >&2   # no CPR → plain, no eraser
        fi
    fi
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

# Dash-count time travel: jump N dirs back through this session's distinct
# history (OLDPWD first, then the recent-places trail). The dir you leave is
# recorded by the precmd hook, so repeating `cd --` cycles a 3-dir ring the
# same way `cd -` cycles two. Vanished targets get the inode treatment.
__bettercd_njump() { # $1 = N (2+)
    _bcd_nj_n="$1"; _bcd_nj_i=0; _bcd_nj_t=""
    _bcd_nj_seen="
$PWD
"
    while IFS= read -r _bcd_nj_d; do
        [ -n "$_bcd_nj_d" ] || continue
        case "$_bcd_nj_seen" in *"
$_bcd_nj_d
"*) continue ;; esac
        _bcd_nj_seen="$_bcd_nj_seen$_bcd_nj_d
"
        _bcd_nj_i=$(( _bcd_nj_i + 1 ))
        if [ "$_bcd_nj_i" -eq "$_bcd_nj_n" ]; then _bcd_nj_t="$_bcd_nj_d"; break; fi
    done <<__BCD_EOF__
${OLDPWD-}
${_BETTERCD_RECENT-}
__BCD_EOF__
    if [ -z "$_bcd_nj_t" ]; then
        if [ -t 2 ] && [ -z "${NO_COLOR-}" ] && [ "${TERM-}" != dumb ]; then
            printf '\033[38;5;213m✻\033[0m \033[2monly %s distinct dir(s) of history so far — need %s\033[0m\n' "$_bcd_nj_i" "$_bcd_nj_n" >&2
        else
            printf 'bettercd: only %s distinct dir(s) of history so far — need %s\n' "$_bcd_nj_i" "$_bcd_nj_n" >&2
        fi
        return 1
    fi
    if [ ! -d "$_bcd_nj_t" ]; then
        __bettercd_vanished "$_bcd_nj_t"
        return $?
    fi
    if __bettercd_delegate "$_bcd_nj_t"; then
        __bettercd_clear_miss
        if [ -t 2 ] && [ -z "${NO_COLOR-}" ] && [ "${TERM-}" != dumb ]; then
            printf '\033[38;5;213m✻\033[0m \033[2m↶%s\033[0m \033[1;36m%s\033[0m\n' "$_bcd_nj_n" "$(__bettercd_home_rel "$_bcd_nj_t")" >&2
        fi
        return 0
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

# --- F1-F7 row model: pins, lazy metadata caches, fuzzy filter ---------------
# Everything here obeys the perf law: expensive facts (git status, tags, mtime)
# are computed ONLY for rows that actually get looked at, ONLY once, cached in
# session vars keyed by path; every cache lookup and every per-keystroke filter
# is a pure string operation with zero forks.

# The pins file: one absolute path per line. Loaded once per menu open, written
# atomically (temp + mv) on every toggle so a crash mid-write never truncates it.
__bettercd_pins_file() { printf '%s/bettercd/pins' "${XDG_CONFIG_HOME:-$HOME/.config}"; }

__bettercd_pins_load() {
    [ -n "${_BETTERCD_PINS_LOADED-}" ] && return 0
    _BETTERCD_PINS_LOADED=1
    _BETTERCD_PINS=""
    _bcd_pf="$(__bettercd_pins_file)"
    [ -f "$_bcd_pf" ] || return 0
    while IFS= read -r _bcd_pl; do
        [ -n "$_bcd_pl" ] || continue
        _BETTERCD_PINS="$_BETTERCD_PINS$_bcd_pl
"
    done < "$_bcd_pf"
    return 0
}

# Pins are newline-TERMINATED entries, so the leading-newline membership test
# delimits every one exactly (same convention the pool builder uses).
__bettercd_is_pinned() { # $1 path → rc0 if pinned
    case "
${_BETTERCD_PINS-}" in *"
$1
"*) return 0 ;; esac
    return 1
}

__bettercd_pin_toggle() { # $1 real path → flip pin state, persist atomically
    __bettercd_pins_load
    if __bettercd_is_pinned "$1"; then
        _bcd_np=""
        while IFS= read -r _bcd_pl; do
            [ -n "$_bcd_pl" ] || continue
            [ "$_bcd_pl" = "$1" ] && continue
            _bcd_np="$_bcd_np$_bcd_pl
"
        done <<__BCD_EOF__
${_BETTERCD_PINS-}
__BCD_EOF__
        _BETTERCD_PINS="$_bcd_np"
    else
        _BETTERCD_PINS="${_BETTERCD_PINS-}$1
"
    fi
    _bcd_pf="$(__bettercd_pins_file)"
    command mkdir -p -- "${_bcd_pf%/*}" 2>/dev/null
    _bcd_ptmp="$_bcd_pf.$$"
    if printf '%s' "${_BETTERCD_PINS-}" > "$_bcd_ptmp" 2>/dev/null; then
        command mv -f "$_bcd_ptmp" "$_bcd_pf" 2>/dev/null
    fi
    return 0
}

# F2: mark the dir as a project — create .project/ + an empty status file if
# absent. Never deletes (it is a marker). rc0 = created, rc1 = already there.
__bettercd_project_mark() { # $1 dir
    [ -e "$1/.project" ] && return 1
    command mkdir -p -- "$1/.project" 2>/dev/null || return 1
    : > "$1/.project/status" 2>/dev/null
    return 0
}

# F4 git state classifier: clean|mod|untr|'' (empty = not a git dir). Cheap gate
# ([ -d .git ]) before the one git invocation. Precedence: untracked wins over
# tracked-mods (orange > yellow), clean only when porcelain is empty.
__bettercd_gitclass() { # $1 dir → prints clean|mod|untr|''
    [ -d "$1/.git" ] || return 0
    _bcd_gc_u=0; _bcd_gc_m=0
    while IFS= read -r _bcd_gc_l; do
        [ -n "$_bcd_gc_l" ] || continue
        case "$_bcd_gc_l" in
            '??'*) _bcd_gc_u=1 ;;
            *)     _bcd_gc_m=1 ;;
        esac
    done <<__BCD_EOF__
$(command git -C "$1" --no-optional-locks status --porcelain 2>/dev/null | head -40)
__BCD_EOF__
    if [ "$_bcd_gc_u" = 1 ]; then printf untr
    elif [ "$_bcd_gc_m" = 1 ]; then printf mod
    else printf clean; fi
}

# F5 mtime (portable BSD/GNU): YYYY-MM-DD of the dir, '-' if unreadable.
__bettercd_rowmtime() { # $1 dir
    _bcd_mt="$(command stat -f '%Sm' -t '%Y-%m-%d' "$1" 2>/dev/null)"
    [ -n "$_bcd_mt" ] || _bcd_mt="$(command stat -c '%y' "$1" 2>/dev/null)"
    _bcd_mt="${_bcd_mt%% *}"
    [ -n "$_bcd_mt" ] || _bcd_mt="-"
    printf '%s' "$_bcd_mt"
}

# F5 version: .project/status `version:` line, else latest git tag, else '-'.
__bettercd_rowver() { # $1 dir
    if [ -f "$1/.project/status" ]; then
        _bcd_rv=""
        while IFS= read -r _bcd_rvl; do
            case "$_bcd_rvl" in
                version:*) _bcd_rv="${_bcd_rvl#version:}"; _bcd_rv="${_bcd_rv# }"; break ;;
            esac
        done < "$1/.project/status"
        if [ -n "$_bcd_rv" ]; then printf '%s' "${_bcd_rv%% *}"; return 0; fi
    fi
    if [ -d "$1/.git" ]; then
        _bcd_rv="$(command git -C "$1" describe --tags --abbrev=0 2>/dev/null)"
        if [ -n "$_bcd_rv" ]; then printf '%s' "$_bcd_rv"; return 0; fi
    fi
    printf '%s' '-'
}

# F5 shipped: y if .project/status last_shipped: == version:, n otherwise, ''
# when there is no .project marker at all (so the column stays blank for plain dirs).
__bettercd_rowshipped() { # $1 dir → y|n|''
    [ -e "$1/.project" ] || return 0
    _bcd_sv=""; _bcd_sl=""
    if [ -f "$1/.project/status" ]; then
        while IFS= read -r _bcd_ssl; do
            case "$_bcd_ssl" in
                version:*)      _bcd_sv="${_bcd_ssl#version:}"; _bcd_sv="${_bcd_sv# }"; _bcd_sv="${_bcd_sv%% *}" ;;
                last_shipped:*) _bcd_sl="${_bcd_ssl#last_shipped:}"; _bcd_sl="${_bcd_sl# }"; _bcd_sl="${_bcd_sl%% *}" ;;
            esac
        done < "$1/.project/status"
    fi
    if [ -n "$_bcd_sv" ] && [ "$_bcd_sv" = "$_bcd_sl" ]; then printf y; else printf n; fi
}

# Color/bold cache (both views): "<git> <proj>\t<path>". git∈clean|mod|untr|-,
# proj∈0|1. One [ -d .git ] + at most one git status + one [ -e .project ] per
# path, EVER. Populated lazily as rows become visible.
__bettercd_meta_c() { # $1 dir → ensures _BETTERCD_C; sets _bcd_c_git _bcd_c_proj
    _bcd_c_want="$_BETTERCD_TAB$1"
    while IFS= read -r _bcd_c_l; do
        case "$_bcd_c_l" in
            *"$_bcd_c_want")
                _bcd_c_f="${_bcd_c_l%%"$_BETTERCD_TAB"*}"
                _bcd_c_git="${_bcd_c_f%% *}"; _bcd_c_proj="${_bcd_c_f##* }"
                return 0 ;;
        esac
    done <<__BCD_EOF__
${_BETTERCD_C-}
__BCD_EOF__
    _bcd_c_git="$(__bettercd_gitclass "$1")"; [ -n "$_bcd_c_git" ] || _bcd_c_git="-"
    if [ -e "$1/.project" ]; then _bcd_c_proj=1; else _bcd_c_proj=0; fi
    _BETTERCD_C="${_BETTERCD_C-}$_bcd_c_git $_bcd_c_proj$_BETTERCD_TAB$1
"
    return 0
}

# Detail cache (table view only): "<mtime> <ver> <ship>\t<path>". Computed only
# when a row is drawn in detail mode, so compact mode never pays for tags/mtime.
# "3m" / "2h" / "5d" ago — pure arithmetic
__bettercd_ago() { # $1 epoch-then, $2 epoch-now → sets _bcd_ago
    _bcd_agd=$(( $2 - $1 ))
    if   [ "$_bcd_agd" -lt 60 ];     then _bcd_ago="now"
    elif [ "$_bcd_agd" -lt 3600 ];   then _bcd_ago="$(( _bcd_agd / 60 ))m"
    elif [ "$_bcd_agd" -lt 86400 ];  then _bcd_ago="$(( _bcd_agd / 3600 ))h"
    elif [ "$_bcd_agd" -lt 2592000 ]; then _bcd_ago="$(( _bcd_agd / 86400 ))d"
    else _bcd_ago="$(( _bcd_agd / 2592000 ))mo"; fi
}

# load the visits file ONCE per menu open: newest epoch per path; compacts
# the file when it grows past ~600 lines (one awk, only then)
__bettercd_visits_load() {
    _BETTERCD_V=""
    _bcd_vf="${XDG_CONFIG_HOME:-$HOME/.config}/bettercd/visits"
    [ -f "$_bcd_vf" ] || return 0
    _BETTERCD_V="$(LC_ALL=C awk '{e[$2]=$1} END{for (d in e) print e[d], d}' "$_bcd_vf" 2>/dev/null)"
    _bcd_vln=0
    while IFS= read -r _bcd_vl; do [ -n "$_bcd_vl" ] && _bcd_vln=$((_bcd_vln + 1)); done < "$_bcd_vf"
    if [ "$_bcd_vln" -gt 600 ]; then
        printf '%s\n' "$_BETTERCD_V" > "$_bcd_vf.tmp" 2>/dev/null && command mv -f "$_bcd_vf.tmp" "$_bcd_vf" 2>/dev/null
    fi
    return 0
}
__bettercd_visited() { # $1 dir → sets _bcd_vis ("3h" or "-")
    _bcd_vis="-"
    [ -n "${_BETTERCD_V-}" ] || return 0
    while IFS= read -r _bcd_vl; do
        case "$_bcd_vl" in
            *" $1")
                # shellcheck disable=SC3028  # guarded fallback below
                _bcd_vnow2="${EPOCHSECONDS:-$_BETTERCD_MENU_NOW}"
                __bettercd_ago "${_bcd_vl%% *}" "$_bcd_vnow2"
                _bcd_vis="$_bcd_ago"
                return 0 ;;
        esac
    done <<__BCD_EOF__
$_BETTERCD_V
__BCD_EOF__
    return 0
}

# dir birthtime, portable probe decided once: BSD stat -f %SB, GNU stat -c %w
__bettercd_created() { # $1 dir → sets _bcd_crt (YYYY-MM-DD or "-")
    if [ -z "${_BETTERCD_STATF-}" ]; then
        if command stat -f '%SB' -t '%Y-%m-%d' "$HOME" >/dev/null 2>&1; then _BETTERCD_STATF=bsd
        elif command stat -c '%w' "$HOME" >/dev/null 2>&1; then _BETTERCD_STATF=gnu
        else _BETTERCD_STATF=none; fi
    fi
    case "$_BETTERCD_STATF" in
        bsd) _bcd_crt="$(command stat -f '%SB' -t '%Y-%m-%d' "$1" 2>/dev/null)" ;;
        gnu) _bcd_crt="$(command stat -c '%w' "$1" 2>/dev/null)"; _bcd_crt="${_bcd_crt%% *}" ;;
        *)   _bcd_crt="-" ;;
    esac
    case "$_bcd_crt" in ''|-*) _bcd_crt="-" ;; esac
    return 0
}

__bettercd_meta_d() { # $1 dir → sets _bcd_d_mt _bcd_d_ver _bcd_d_ship _bcd_d_vis _bcd_d_crt _bcd_d_sz
    _bcd_d_want="$_BETTERCD_TAB$1"
    while IFS= read -r _bcd_d_l; do
        case "$_bcd_d_l" in
            *"$_bcd_d_want")
                _bcd_d_f="${_bcd_d_l%%"$_BETTERCD_TAB"*}"
                _bcd_d_mt="${_bcd_d_f%% *}";  _bcd_d_rest="${_bcd_d_f#* }"
                _bcd_d_ver="${_bcd_d_rest%% *}"; _bcd_d_rest="${_bcd_d_rest#* }"
                _bcd_d_ship="${_bcd_d_rest%% *}"; _bcd_d_rest="${_bcd_d_rest#* }"
                _bcd_d_vis="${_bcd_d_rest%% *}"; _bcd_d_rest="${_bcd_d_rest#* }"
                _bcd_d_crt="${_bcd_d_rest%% *}"; _bcd_d_sz="${_bcd_d_rest##* }"
                return 0 ;;
        esac
    done <<__BCD_EOF__
${_BETTERCD_D2-}
__BCD_EOF__
    _bcd_d_mt="$(__bettercd_rowmtime "$1")"
    _bcd_d_ver="$(__bettercd_rowver "$1")"
    _bcd_d_ship="$(__bettercd_rowshipped "$1")"; [ -n "$_bcd_d_ship" ] || _bcd_d_ship="-"
    __bettercd_visited "$1"; _bcd_d_vis="$_bcd_vis"
    __bettercd_created "$1"; _bcd_d_crt="$_bcd_crt"
    _bcd_d_sz="-"
    _BETTERCD_D2="${_BETTERCD_D2-}$_bcd_d_mt $_bcd_d_ver $_bcd_d_ship $_bcd_d_vis $_bcd_d_crt $_bcd_d_sz$_BETTERCD_TAB$1
"
    return 0
}


# patch the cached size field for one path (after an on-demand `s` du)
__bettercd_meta_szset() { # $1 dir, $2 human size
    _bcd_sz_want="$_BETTERCD_TAB$1"
    _bcd_sz_new=""
    while IFS= read -r _bcd_sz_l; do
        [ -n "$_bcd_sz_l" ] || continue
        case "$_bcd_sz_l" in
            *"$_bcd_sz_want")
                _bcd_sz_f="${_bcd_sz_l%%"$_BETTERCD_TAB"*}"
                _bcd_sz_pre="${_bcd_sz_f% *}"
                _bcd_sz_new="$_bcd_sz_new$_bcd_sz_pre $2$_BETTERCD_TAB$1
"  ;;
            *) _bcd_sz_new="$_bcd_sz_new$_bcd_sz_l
"  ;;
        esac
    done <<__BCD_EOF__
${_BETTERCD_D2-}
__BCD_EOF__
    _BETTERCD_D2="$_bcd_sz_new"
    return 0
}
# Drop a path's cached color/detail records so the next draw recomputes them —
# used after `t` marks a dir a project (its bold/icon/version must refresh).
__bettercd_meta_inval() { # $1 dir
    _bcd_mi_want="$_BETTERCD_TAB$1"
    _bcd_mi_c=""
    while IFS= read -r _bcd_mi_l; do
        [ -n "$_bcd_mi_l" ] || continue
        case "$_bcd_mi_l" in *"$_bcd_mi_want") continue ;; esac
        _bcd_mi_c="$_bcd_mi_c$_bcd_mi_l
"
    done <<__BCD_EOF__
${_BETTERCD_C-}
__BCD_EOF__
    _BETTERCD_C="$_bcd_mi_c"
    _bcd_mi_d=""
    while IFS= read -r _bcd_mi_l; do
        [ -n "$_bcd_mi_l" ] || continue
        case "$_bcd_mi_l" in *"$_bcd_mi_want") continue ;; esac
        _bcd_mi_d="$_bcd_mi_d$_bcd_mi_l
"
    done <<__BCD_EOF__
${_BETTERCD_D2-}
__BCD_EOF__
    _BETTERCD_D2="$_bcd_mi_d"
}

# F7 fuzzy subsequence match — pure, fork-free, shell-agnostic. Both args must
# already be lowercased (the loop pre-lowercases haystacks once at build and the
# query once per keystroke, so per-keystroke filtering over the whole pool costs
# zero forks). Walks the query char by char, advancing past each match in the
# haystack. The `*"$c"*` patterns are literal globs in the SOURCE, so zsh treats
# them as patterns (unlike a whole pattern taken from a variable, which zsh only
# globs with $~ — the reason we avoid variable case-patterns here).
__bettercd_subseq() { # $1 lc-query, $2 lc-haystack → rc0 if subsequence
    _bcd_sq_q="$1"; _bcd_sq_h="$2"
    [ -n "$_bcd_sq_q" ] || return 0
    while [ -n "$_bcd_sq_q" ]; do
        _bcd_sq_c="${_bcd_sq_q%"${_bcd_sq_q#?}"}"   # first query char
        case "$_bcd_sq_h" in
            *"$_bcd_sq_c"*) _bcd_sq_h="${_bcd_sq_h#*"$_bcd_sq_c"}"; _bcd_sq_q="${_bcd_sq_q#?}" ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# Testable case-insensitive matcher (lowercases both sides itself).
__bettercd_fuzzy() { # $1 query, $2 haystack → rc0 if subsequence match
    [ -n "$1" ] || return 0
    _bcd_fz_q="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    _bcd_fz_h="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
    __bettercd_subseq "$_bcd_fz_q" "$_bcd_fz_h"
}

# Sort a newline path list by basename, case-insensitive A-Z. One sort fork,
# only when the user cycles to name-sort (never on the arrow-key hot path).
__bettercd_sort_name() { # stdin: paths → stdout: name-sorted paths
    while IFS= read -r _bcd_snl; do
        [ -n "$_bcd_snl" ] || continue
        printf '%s%s%s\n' "${_bcd_snl##*/}" "$_BETTERCD_TAB" "$_bcd_snl"
    done | LC_ALL=C command sort -f | while IFS= read -r _bcd_snk; do
        printf '%s\n' "${_bcd_snk#*"$_BETTERCD_TAB"}"
    done
}

# Pure (fork-free) lowercase — a 26-arm translation, one char at a time. Used to
# lowercase display paths for the filter so per-keystroke matching stays forkless.
__bettercd_lc() { # $1 → sets _bcd_lc
    _bcd_lc=""; _bcd_lc_r="$1"
    while [ -n "$_bcd_lc_r" ]; do
        _bcd_lc_c="${_bcd_lc_r%"${_bcd_lc_r#?}"}"; _bcd_lc_r="${_bcd_lc_r#?}"
        case "$_bcd_lc_c" in
            A) _bcd_lc_c=a ;; B) _bcd_lc_c=b ;; C) _bcd_lc_c=c ;; D) _bcd_lc_c=d ;;
            E) _bcd_lc_c=e ;; F) _bcd_lc_c=f ;; G) _bcd_lc_c=g ;; H) _bcd_lc_c=h ;;
            I) _bcd_lc_c=i ;; J) _bcd_lc_c=j ;; K) _bcd_lc_c=k ;; L) _bcd_lc_c=l ;;
            M) _bcd_lc_c=m ;; N) _bcd_lc_c=n ;; O) _bcd_lc_c=o ;; P) _bcd_lc_c=p ;;
            Q) _bcd_lc_c=q ;; R) _bcd_lc_c=r ;; S) _bcd_lc_c=s ;; T) _bcd_lc_c=t ;;
            U) _bcd_lc_c=u ;; V) _bcd_lc_c=v ;; W) _bcd_lc_c=w ;; X) _bcd_lc_c=x ;;
            Y) _bcd_lc_c=y ;; Z) _bcd_lc_c=z ;;
        esac
        _bcd_lc="$_bcd_lc$_bcd_lc_c"
    done
}

# Pad/truncate a string to N display chars, into _bcd_pad_out (no fork — called
# per visible row while drawing the detail table). Truncates with an ellipsis.
__bettercd_pad() { # $1 str, $2 width
    _bcd_pad_out=""; _bcd_pad_r="$1"; _bcd_pad_i=0
    if [ "${#1}" -gt "$2" ]; then
        while [ "$_bcd_pad_i" -lt $(( $2 - 1 )) ]; do
            _bcd_pad_c="${_bcd_pad_r%"${_bcd_pad_r#?}"}"; _bcd_pad_r="${_bcd_pad_r#?}"
            _bcd_pad_out="$_bcd_pad_out$_bcd_pad_c"; _bcd_pad_i=$((_bcd_pad_i + 1))
        done
        _bcd_pad_out="$_bcd_pad_out$_BETTERCD_ELL"
    else
        _bcd_pad_out="$1"; _bcd_pad_i="${#1}"
        while [ "$_bcd_pad_i" -lt "$2" ]; do _bcd_pad_out="$_bcd_pad_out "; _bcd_pad_i=$((_bcd_pad_i + 1)); done
    fi
}

# F6 modified-sort: order the pool newest-first by dir mtime. mtimes are pulled
# through the detail cache (so they are computed at most once), then a single
# sort fork orders them — only when the user first selects this sort, never on
# the arrow-key hot path.
__bettercd_menu_sort_mtime() { # sets _bcd_ml_op
    _bcd_smt=""
    while IFS= read -r _bcd_smp; do
        [ -n "$_bcd_smp" ] || continue
        __bettercd_meta_d "$_bcd_smp"
        _bcd_smt="$_bcd_smt$_bcd_d_mt$_BETTERCD_TAB$_bcd_smp
"
    done <<__BCD_EOF__
$_bcd_ml_pool
__BCD_EOF__
    _bcd_ml_op="$(printf '%s' "$_bcd_smt" | LC_ALL=C command sort -r | while IFS= read -r _bcd_sml; do
        [ -n "$_bcd_sml" ] && printf '%s\n' "${_bcd_sml#*"$_BETTERCD_TAB"}"
    done)"
}

# --- W3 per-column sort engine (header-click) --------------------------------
# All of this runs ONLY when the user changes the sort (never the hot key loop),
# and obeys the perf law: visited is a pure lookup, created does at most one
# stat per dir (cached), and version/ship/size NEVER bulk-compute — they rank
# only rows already in the detail cache and sink the rest.

# Reverse a newline list (one awk fork). Used to flip a primary sort order.
__bettercd_reverse() { LC_ALL=C command awk '{a[NR]=$0} END{for (i=NR;i>=1;i--) print a[i]}'; }

# Raw visit epoch for a path from the loaded visits map (0 if never visited).
__bettercd_visited_epoch() { # $1 dir → sets _bcd_ve
    _bcd_ve=0
    [ -n "${_BETTERCD_V-}" ] || return 0
    while IFS= read -r _bcd_vel; do
        case "$_bcd_vel" in
            *" $1") _bcd_ve="${_bcd_vel%% *}"; return 0 ;;
        esac
    done <<__BCD_EOF__
$_BETTERCD_V
__BCD_EOF__
    return 0
}

# Peek an ALREADY-cached detail field WITHOUT computing it (the perf law for
# version/ship/size). $2 ∈ version|ship|size → sets _bcd_peek ('' if uncached).
__bettercd_meta_d_peek() { # $1 dir, $2 field
    _bcd_peek=""
    _bcd_pk_want="$_BETTERCD_TAB$1"
    while IFS= read -r _bcd_pk_l; do
        case "$_bcd_pk_l" in
            *"$_bcd_pk_want")
                _bcd_pk_f="${_bcd_pk_l%%"$_BETTERCD_TAB"*}"  # "mt ver ship vis crt sz"
                _bcd_pk_r="${_bcd_pk_f#* }"                   # drop mt
                _bcd_pk_ver="${_bcd_pk_r%% *}";  _bcd_pk_r="${_bcd_pk_r#* }"
                _bcd_pk_ship="${_bcd_pk_r%% *}"; _bcd_pk_r="${_bcd_pk_r#* }"
                _bcd_pk_r="${_bcd_pk_r#* }"                   # drop vis
                _bcd_pk_r="${_bcd_pk_r#* }"                   # drop crt
                _bcd_pk_sz="$_bcd_pk_r"
                case "$2" in
                    version) _bcd_peek="$_bcd_pk_ver" ;;
                    ship)    _bcd_peek="$_bcd_pk_ship" ;;
                    size)    _bcd_peek="$_bcd_pk_sz" ;;
                esac
                return 0 ;;
        esac
    done <<__BCD_EOF__
${_BETTERCD_D2-}
__BCD_EOF__
    return 0
}

# Order the pool by one detail column. $1 ∈ visited|created|version|ship|size,
# $2 = 'rev' to reverse the primary (descending) order. Primary = newest /
# largest / highest first. Sets _bcd_ml_op; sets _bcd_ml_cachenote=1 when a
# cached-only column could not rank some rows (they sink to the bottom).
__bettercd_menu_sort_field() { # $1 col, $2 rev
    _bcd_sf_col="$1"; _bcd_sf_rev="$2"
    _bcd_sf_keyed=""; _bcd_sf_tail=""
    while IFS= read -r _bcd_sf_p; do
        [ -n "$_bcd_sf_p" ] || continue
        case "$_bcd_sf_col" in
            visited)
                __bettercd_visited_epoch "$_bcd_sf_p"
                _bcd_sf_keyed="$_bcd_sf_keyed$_bcd_ve$_BETTERCD_TAB$_bcd_sf_p
" ;;
            created)
                __bettercd_meta_d "$_bcd_sf_p"
                _bcd_sf_k="$_bcd_d_crt"; [ "$_bcd_sf_k" = "-" ] && _bcd_sf_k="0000-00-00"
                _bcd_sf_keyed="$_bcd_sf_keyed$_bcd_sf_k$_BETTERCD_TAB$_bcd_sf_p
" ;;
            *)
                __bettercd_meta_d_peek "$_bcd_sf_p" "$_bcd_sf_col"
                if [ -n "$_bcd_peek" ] && [ "$_bcd_peek" != "-" ]; then
                    _bcd_sf_keyed="$_bcd_sf_keyed$_bcd_peek$_BETTERCD_TAB$_bcd_sf_p
"
                else
                    _bcd_sf_tail="$_bcd_sf_tail$_bcd_sf_p
"; _bcd_ml_cachenote=1
                fi ;;
        esac
    done <<__BCD_EOF__
$_bcd_ml_pool
__BCD_EOF__
    case "$_bcd_sf_col" in
        visited) _bcd_sf_sorted="$(printf '%s' "$_bcd_sf_keyed" | LC_ALL=C command sort -t "$_BETTERCD_TAB" -k1,1 -rn)" ;;
        *)       _bcd_sf_sorted="$(printf '%s' "$_bcd_sf_keyed" | LC_ALL=C command sort -t "$_BETTERCD_TAB" -k1,1 -r)" ;;
    esac
    # NB: newline-terminate the stream (command-sub strips the trailing \n) so
    # the while-read never drops the last row — the sort-name trailing-nl bug.
    _bcd_sf_stripped="$(printf '%s\n' "$_bcd_sf_sorted" | while IFS= read -r _bcd_sf_l; do
        [ -n "$_bcd_sf_l" ] && printf '%s\n' "${_bcd_sf_l#*"$_BETTERCD_TAB"}"
    done)"
    [ "$_bcd_sf_rev" = rev ] && _bcd_sf_stripped="$(printf '%s' "$_bcd_sf_stripped" | __bettercd_reverse)"
    _bcd_ml_op="$_bcd_sf_stripped
$_bcd_sf_tail"
}

# Cycle the sort state when a table header column is clicked: first click =
# that column's primary order, second = reversed, third = back to recent.
# Clicking a DIFFERENT column starts its primary order.
__bettercd_sort_click() { # $1 col
    case "$_bcd_ml_sort" in
        "$1")     _bcd_ml_sort="$1-desc" ;;
        "$1-desc") _bcd_ml_sort=recent ;;
        *)        _bcd_ml_sort="$1" ;;
    esac
}

# Footer label for the active sort, with a direction arrow (↑ ascending, ↓
# descending). Name's primary is A→Z (↑); every other column's primary is
# newest/largest/highest first (↓). Sets _bcd_sortlabel.
__bettercd_sort_label() {
    _bcd_sl_col="$_bcd_ml_sort"; _bcd_sl_rev=""
    case "$_bcd_ml_sort" in *-desc) _bcd_sl_col="${_bcd_ml_sort%-desc}"; _bcd_sl_rev=1 ;; esac
    case "$_bcd_sl_col" in
        recent) _bcd_sortlabel="recent" ;;
        name)   if [ -n "$_bcd_sl_rev" ]; then _bcd_sortlabel="name$_BETTERCD_DARR"; else _bcd_sortlabel="name$_BETTERCD_UARR"; fi ;;
        *)      if [ -n "$_bcd_sl_rev" ]; then _bcd_sortlabel="$_bcd_sl_col$_BETTERCD_UARR"; else _bcd_sortlabel="$_bcd_sl_col$_BETTERCD_DARR"; fi ;;
    esac
}

# Map a click's column x (1-based) to a table column name, or '' if the click
# fell in a gutter/gap. Pure math mirroring the row field layout in the draw fn
# (gutter 2 · Directory tnw · visited 8 · modified 11 · created 11 · version 10
# · ship 4 · size), so it is unit-testable with no tty. tnw = cols-58 (min 16).
__bettercd_col_resolve() { # $1 x, $2 cols → sets _bcd_col
    _bcd_col=""
    _bcd_cr_x="$1"
    _bcd_cr_t=$(( $2 - 58 )); [ "$_bcd_cr_t" -ge 16 ] || _bcd_cr_t=16
    if   [ "$_bcd_cr_x" -ge 3 ]                  && [ "$_bcd_cr_x" -le $(( 2 + _bcd_cr_t )) ];  then _bcd_col=name
    elif [ "$_bcd_cr_x" -ge $(( 4 + _bcd_cr_t )) ]  && [ "$_bcd_cr_x" -le $(( 11 + _bcd_cr_t )) ]; then _bcd_col=visited
    elif [ "$_bcd_cr_x" -ge $(( 13 + _bcd_cr_t )) ] && [ "$_bcd_cr_x" -le $(( 23 + _bcd_cr_t )) ]; then _bcd_col=modified
    elif [ "$_bcd_cr_x" -ge $(( 25 + _bcd_cr_t )) ] && [ "$_bcd_cr_x" -le $(( 35 + _bcd_cr_t )) ]; then _bcd_col=created
    elif [ "$_bcd_cr_x" -ge $(( 37 + _bcd_cr_t )) ] && [ "$_bcd_cr_x" -le $(( 46 + _bcd_cr_t )) ]; then _bcd_col=version
    elif [ "$_bcd_cr_x" -ge $(( 47 + _bcd_cr_t )) ] && [ "$_bcd_cr_x" -le $(( 50 + _bcd_cr_t )) ]; then _bcd_col=ship
    elif [ "$_bcd_cr_x" -ge $(( 51 + _bcd_cr_t )) ]; then _bcd_col=size
    fi
}

# Emit one base row: <realpath>\t<display>\t<extflag>\t<lc-realpath>. Display is
# home-relative unless the full-path toggle (F8 `.`) is on. lc is precomputed
# here (once per stage-A rebuild) so the filter never lowercases in the hot loop.
__bettercd_stageA_emit() { # $1 path, $2 extflag
    if [ "${_bcd_ml_full-0}" = 1 ]; then _bcd_ed="$1"
    else
        case "$1" in
            "$HOME")   _bcd_ed="~" ;;
            "$HOME"/*) _bcd_ed="~${1#"$HOME"}" ;;
            *)         _bcd_ed="$1" ;;
        esac
    fi
    __bettercd_lc "$1"
    _bcd_ml_base="$_bcd_ml_base$1$_BETTERCD_TAB$_bcd_ed$_BETTERCD_TAB$2$_BETTERCD_TAB$_bcd_lc
"
    _bcd_ml_seen="$_bcd_ml_seen$1
"
}

# Stage A (rare — only on open / sort / pin / full-path / extend changes): build
# the ordered base list. Pins float to the very top in pin order (above OLDPWD),
# then the sorted pool (non-pinned), then de-duplicated extension results.
__bettercd_menu_stageA() {
    _bcd_ml_base=""; _bcd_ml_seen=""; _bcd_ml_cachenote=0
    # W3 refinement: pins float to the top ONLY on the default (recent) order.
    # Under ANY explicit column sort they take their TRUE data rank (the ⚑ glyph
    # stays — draw marks pins by identity, not position). To rank a pin that is
    # not already in the recent pool, fold the pins INTO the sort input; the
    # per-row dedupe below drops any that also live in the pool.
    _bcd_ml_pinfloat=1
    case "$_bcd_ml_sort" in recent|'') ;; *) _bcd_ml_pinfloat=0 ;; esac
    _bcd_sa_savepool="$_bcd_ml_pool"
    if [ "$_bcd_ml_pinfloat" = 0 ] && [ -n "${_BETTERCD_PINS-}" ]; then
        _bcd_ml_pool="${_BETTERCD_PINS}
${_bcd_sa_savepool}"
    fi
    case "$_bcd_ml_sort" in
        name)         _bcd_ml_op="$(printf '%s\n' "$_bcd_ml_pool" | __bettercd_sort_name)" ;;
        name-desc)     _bcd_ml_op="$(printf '%s\n' "$_bcd_ml_pool" | __bettercd_sort_name | __bettercd_reverse)" ;;
        modified)     __bettercd_menu_sort_mtime ;;
        modified-desc) __bettercd_menu_sort_mtime; _bcd_ml_op="$(printf '%s\n' "$_bcd_ml_op" | __bettercd_reverse)" ;;
        visited)      __bettercd_menu_sort_field visited '' ;;
        visited-desc)  __bettercd_menu_sort_field visited rev ;;
        created)      __bettercd_menu_sort_field created '' ;;
        created-desc)  __bettercd_menu_sort_field created rev ;;
        version)      __bettercd_menu_sort_field version '' ;;
        version-desc)  __bettercd_menu_sort_field version rev ;;
        ship)         __bettercd_menu_sort_field ship '' ;;
        ship-desc)     __bettercd_menu_sort_field ship rev ;;
        size)         __bettercd_menu_sort_field size '' ;;
        size-desc)     __bettercd_menu_sort_field size rev ;;
        *)            _bcd_ml_op="$_bcd_ml_pool" ;;
    esac
    _bcd_ml_pool="$_bcd_sa_savepool"   # restore canonical pool (pins were folded in only for the sort)
    if [ "$_bcd_ml_pinfloat" = 1 ]; then
        while IFS= read -r _bcd_ap; do
            [ -n "$_bcd_ap" ] || continue
            [ -d "$_bcd_ap" ] || continue
            [ "$_bcd_ap" = "$PWD" ] && continue
            case "
$_bcd_ml_seen" in *"
$_bcd_ap
"*) continue ;; esac
            __bettercd_stageA_emit "$_bcd_ap" 0
        done <<__BCD_EOF__
${_BETTERCD_PINS-}
__BCD_EOF__
    fi
    while IFS= read -r _bcd_ap; do
        [ -n "$_bcd_ap" ] || continue
        case "
$_bcd_ml_seen" in *"
$_bcd_ap
"*) continue ;; esac
        __bettercd_stageA_emit "$_bcd_ap" 0
    done <<__BCD_EOF__
$_bcd_ml_op
__BCD_EOF__
    while IFS= read -r _bcd_ap; do
        [ -n "$_bcd_ap" ] || continue
        [ "$_bcd_ap" = "$PWD" ] && continue
        [ -d "$_bcd_ap" ] || continue
        case "
$_bcd_ml_seen" in *"
$_bcd_ap
"*) continue ;; esac
        __bettercd_stageA_emit "$_bcd_ap" 1
    done <<__BCD_EOF__
${_bcd_ml_ext-}
__BCD_EOF__
    # count the base (pre-filter) rows — the window height is sized to THIS, not
    # to the filtered count, so typing a filter never changes the height (and so
    # never triggers a CPR re-measure that would swallow fast-typed keystrokes).
    _bcd_ml_basen=0
    while IFS= read -r _bcd_bn; do [ -n "$_bcd_bn" ] && _bcd_ml_basen=$((_bcd_ml_basen + 1)); done <<__BCD_EOF__
$_bcd_ml_base
__BCD_EOF__
}

# Stage B (per keystroke while filtering): filter the base list by the active
# preset AND fuzzy query into the drawable row list. Both are pure string ops —
# preset uses builtin [ -e ]/[ -d ] tests, the query a fork-free subsequence
# walk over the precomputed lowercase paths. Zero forks over the whole pool.
__bettercd_menu_stageB() {
    _bcd_ml_rows=""; _bcd_ml_list=""; _bcd_ml_n=0; _bcd_ml_qmatched=""
    _bcd_ml_lcq=""
    if [ -n "$_bcd_ml_query" ]; then __bettercd_lc "$_bcd_ml_query"; _bcd_ml_lcq="$_bcd_lc"; fi
    # W7 query-stack: filter the SOURCE (base for a full rebuild, or the previous
    # prefix's already-matched subset when a character was just appended — the
    # subsequence-match set only shrinks, so the smaller subset is sufficient).
    # Capture the matched full base lines into _bcd_ml_qmatched so the next
    # keystroke can filter THAT instead of the whole base.
    while IFS= read -r _bcd_br; do
        [ -n "$_bcd_br" ] || continue
        _bcd_brp="${_bcd_br%%"$_BETTERCD_TAB"*}"
        _bcd_brest="${_bcd_br#*"$_BETTERCD_TAB"}"
        _bcd_bd="${_bcd_brest%%"$_BETTERCD_TAB"*}"
        _bcd_brest="${_bcd_brest#*"$_BETTERCD_TAB"}"
        _bcd_bx="${_bcd_brest%%"$_BETTERCD_TAB"*}"
        _bcd_blow="${_bcd_brest#*"$_BETTERCD_TAB"}"
        case "$_bcd_ml_preset" in
            proj)   [ -e "$_bcd_brp/.project" ] || continue ;;
            git)    [ -d "$_bcd_brp/.git" ] || continue ;;
            pinned) __bettercd_is_pinned "$_bcd_brp" || continue ;;
        esac
        if [ -n "$_bcd_ml_lcq" ]; then
            __bettercd_subseq "$_bcd_ml_lcq" "$_bcd_blow" || continue
        fi
        _bcd_ml_rows="$_bcd_ml_rows$_bcd_brp$_BETTERCD_TAB$_bcd_bd$_BETTERCD_TAB$_bcd_bx
"
        _bcd_ml_list="$_bcd_ml_list$_bcd_brp
"
        _bcd_ml_qmatched="$_bcd_ml_qmatched$_bcd_br
"
        _bcd_ml_n=$((_bcd_ml_n + 1))
    done <<__BCD_EOF__
${_bcd_ml_qsrc-}
__BCD_EOF__
    [ "$_bcd_ml_sel" -ge "$_bcd_ml_n" ] && _bcd_ml_sel=$(( _bcd_ml_n - 1 ))
    [ "$_bcd_ml_sel" -lt 0 ] && _bcd_ml_sel=0
    __bettercd_menu_geom
}

# Window geometry: 12 rows + one per pin, clamped to the terminal height, then
# clamped to the row count. Keeps the selection inside the viewport.
__bettercd_menu_geom() {
    _bcd_np=0
    while IFS= read -r _bcd_gl; do [ -n "$_bcd_gl" ] && _bcd_np=$((_bcd_np + 1)); done <<__BCD_EOF__
${_BETTERCD_PINS-}
__BCD_EOF__
    _bcd_ml_vis=$(( 12 + _bcd_np ))
    _bcd_lmax="${LINES:-24}"; _bcd_lmax=$((_bcd_lmax - 6))
    # realcmd parks the typed query on the REAL command line, which sits ABOVE
    # the frame — reserve one extra row so that line can never scroll off the top
    # (else the query would land on a blank spacer masquerading as the cmd line).
    [ "${_bcd_ml_pmode:-fallback}" = realcmd ] && _bcd_lmax=$((_bcd_lmax - 1))
    [ "$_bcd_lmax" -ge 5 ] || _bcd_lmax=5
    [ "$_bcd_ml_vis" -le "$_bcd_lmax" ] || _bcd_ml_vis="$_bcd_lmax"
    # clamp to the UNFILTERED base count (stable while filtering), not the live
    # filtered count — keeps the height fixed so a filter keystroke never remeasures
    [ "$_bcd_ml_vis" -le "${_bcd_ml_basen:-0}" ] || _bcd_ml_vis="${_bcd_ml_basen:-0}"
    [ "$_bcd_ml_vis" -ge 1 ] || _bcd_ml_vis=1
    # L1 query-echo + L2 context + rows + position + legend + keys
    # realcmd: header is the FIRST frame line (no spacer — the tinted header
    # provides the visual separation now). fallback keeps the ⌕ echo line.
    if [ "${_bcd_ml_pmode:-fallback}" = realcmd ]; then
        _bcd_ml_lines=$(( _bcd_ml_vis + 4 )); _bcd_ml_rowoff=1
    else
        _bcd_ml_lines=$(( _bcd_ml_vis + 5 )); _bcd_ml_rowoff=2
    fi
    [ "$_bcd_ml_off" -gt $(( _bcd_ml_n - _bcd_ml_vis )) ] && _bcd_ml_off=$(( _bcd_ml_n - _bcd_ml_vis ))
    [ "$_bcd_ml_off" -lt 0 ] && _bcd_ml_off=0
    [ "$_bcd_ml_sel" -lt "$_bcd_ml_off" ] && _bcd_ml_off="$_bcd_ml_sel"
    [ "$_bcd_ml_sel" -ge $(( _bcd_ml_off + _bcd_ml_vis )) ] && _bcd_ml_off=$(( _bcd_ml_sel - _bcd_ml_vis + 1 ))
}

# Move the selection onto a specific path after a rebuild (selection follows the
# item when pinning re-orders it), else leave the clamped selection.
__bettercd_menu_reselect() { # $1 path
    _bcd_ri=0; _bcd_rfound=-1
    while IFS= read -r _bcd_rl; do
        [ -n "$_bcd_rl" ] || continue
        [ "$_bcd_rl" = "$1" ] && { _bcd_rfound="$_bcd_ri"; break; }
        _bcd_ri=$((_bcd_ri + 1))
    done <<__BCD_EOF__
$_bcd_ml_list
__BCD_EOF__
    [ "$_bcd_rfound" -ge 0 ] && _bcd_ml_sel="$_bcd_rfound"
}

# F7 extension: when the local pool is thin for a query, reach further — zoxide's
# db first, then a bounded $HOME find (pipe-close kills find early). Results feed
# stage A as dim `+` rows. Runs only on a typing pause, once per query.
# W7(b) STREAMING disk search — replaces the old blocking extend. When a thin
# query settles (a ~0.15s typing pause), a DETACHED singleton job writes zoxide-
# then-bounded-find matches to a private temp stream; the idle tick ingests the
# new results and folds them in as dim `+` rows. Typing never blocks; a query
# change kills the stale job and re-arms; every exit cleans up.
__bettercd_stream_start() { # $1 query — launch the detached search
    __bettercd_stream_stop
    _bcd_ml_streamq="$1"; _bcd_ml_streamn=0
    # SESSION-STABLE path (one per shell, NOT mktemp): so a stale file left by a
    # menu that died ungracefully is CLOBBERED here on the next open rather than
    # leaking a new unique file each time. The job is a detached singleton whose
    # bounded find (head -N → pipe-close) self-terminates even if we never kill it.
    _bcd_ml_streamf="${TMPDIR:-/tmp}/bettercd.$$.stream"
    command rm -f "$_bcd_ml_streamf" 2>/dev/null; : > "$_bcd_ml_streamf" 2>/dev/null
    _bcd_ml_job="$( ( {
            command -v zoxide >/dev/null 2>&1 && command zoxide query --list "$1" 2>/dev/null | head -15
            command find "$HOME" -maxdepth 4 -type d -iname "*$1*" 2>/dev/null | head -15
        } >> "$_bcd_ml_streamf" 2>/dev/null </dev/null & printf '%s' $! ) )"
}
__bettercd_stream_stop() { # kill the job + remove its stream
    [ -n "${_bcd_ml_job-}" ] && command kill "$_bcd_ml_job" 2>/dev/null
    [ -n "${_bcd_ml_streamf-}" ] && command rm -f "$_bcd_ml_streamf" 2>/dev/null
    _bcd_ml_job=""; _bcd_ml_streamf=""; _bcd_ml_streamq=""; _bcd_ml_streamn=0
}
# Ingest new stream lines (past the line count already read); dedupe, append to
# the extension pool, fold into the base. Returns 0 iff new rows landed.
__bettercd_stream_ingest() {
    [ -n "${_bcd_ml_streamf-}" ] && [ -f "$_bcd_ml_streamf" ] || return 1
    # Discard results for a STALE query: the stream is tagged with the query it
    # was launched for; if the user has since typed on, ignore its output.
    [ "${_bcd_ml_streamq-}" = "$_bcd_ml_query" ] || return 1
    _bcd_si_new=""; _bcd_si_i=0
    while IFS= read -r _bcd_si_l; do
        _bcd_si_i=$((_bcd_si_i + 1))
        [ "$_bcd_si_i" -le "${_bcd_ml_streamn:-0}" ] && continue
        [ -n "$_bcd_si_l" ] || continue
        [ -d "$_bcd_si_l" ] || continue
        case "
${_bcd_ml_ext-}" in *"
$_bcd_si_l
"*) continue ;; esac
        _bcd_si_new="$_bcd_si_new$_bcd_si_l
"
    done < "$_bcd_ml_streamf"
    _bcd_ml_streamn="$_bcd_si_i"
    [ -n "$_bcd_si_new" ] || return 1
    _bcd_ml_ext="${_bcd_ml_ext-}$_bcd_si_new"
    _bcd_ml_extq="$_bcd_ml_streamq"
    __bettercd_menu_rebuild A
    return 0
}
# The job finished — one last ingest, then drop back to the slow idle tick.
__bettercd_stream_reap() {
    __bettercd_stream_ingest || :
    [ -n "${_bcd_ml_job-}" ] && _bcd_ml_job=""
    [ -n "${_bcd_ml_streamf-}" ] && command rm -f "$_bcd_ml_streamf" 2>/dev/null
    _bcd_ml_streamf=""
    return 0
}
# Decide (after each key) whether a search should be armed for the current query.
__bettercd_stream_manage() {
    if [ -n "$_bcd_ml_query" ] && [ "$_bcd_ml_n" -lt 5 ] && [ "${#_bcd_ml_query}" -ge 3 ]; then
        if [ "$_bcd_ml_query" != "${_bcd_ml_streamq-}" ] && [ "$_bcd_ml_query" != "${_bcd_ml_extq-}" ]; then
            _bcd_ml_streamwant="$_bcd_ml_query"     # arm; the tick launches after a pause
            [ -n "${_bcd_ml_job-}" ] && __bettercd_stream_stop
        fi
    else
        _bcd_ml_streamwant=""; __bettercd_stream_stop
    fi
}

# Draw the whole menu (header + window + footer) to /dev/tty in ONE printf. Raw
# mode ⇒ lines end \r\n. Reads state from the loop's globals (no `local` here, so
# they are shared). Per-visible-row facts come from the lazy caches: git state,
# project marker, and (detail view only) mtime/version/shipped — each computed at
# most once when a row first becomes visible, then pure string lookups forever.
# Header column SGR: BOLD-WHITE when $1 is the active sort column ($_bcd_hac),
# else bold-dim. Kept fork-free; called once per visible column each table draw.
__bettercd_hcol() { # $1 col name -> sets _bcd_hcs (SGR start, bg preserved)
    # the Directory title is ALWAYS bold-white (user ask); other labels go
    # bold-white only while they are the active sort column
    if [ "$1" = name ] || [ "$1" = "$_bcd_hac" ]; then _bcd_hcs="${_BETTERCD_ESC}[1;97m"
    else _bcd_hcs="${_BETTERCD_ESC}[2m"; fi
}

__bettercd_menu_draw() {
    case $(( _bcd_ml_frame % 4 )) in
        0) _bcd_dc=213 ;; 1) _bcd_dc=219 ;; 2) _bcd_dc=177 ;; 3) _bcd_dc=225 ;;
    esac
    _bcd_dE="$_BETTERCD_ESC"
    _bcd_dL="$_BETTERCD_CR
"
    # W1' L0: in realcmd mode this is an EMPTY SPACER (home for the W5 toast) —
    # the typed query is painted onto the user's REAL command line by the park
    # fn, so it visually continues "cd -- ". In fallback mode (bash / prompt not
    # measurable) the query echoes here after a ⌕ marker, bold-cyan.
    if [ "${_bcd_ml_pmode:-fallback}" = realcmd ]; then
        _bcd_df=""   # no spacer — the query lives on the real command line
    else
        _bcd_df="  ${_bcd_dE}[38;5;213m$_BETTERCD_MAG${_bcd_dE}[0m ${_bcd_dE}[1;36m$_bcd_ml_query${_bcd_dE}[0m${_bcd_dE}[K$_bcd_dL"
    fi
    # L2: context — the table column header, else the recent-places banner with
    # a dim match-count (matched/total) once a query is filtering.
    if [ "$_bcd_ml_table" = 1 ]; then
        _bcd_tnw=$(( _bcd_ml_cols - 58 )); [ "$_bcd_tnw" -ge 16 ] || _bcd_tnw=16
        __bettercd_pad "Directory" "$_bcd_tnw"; _bcd_thn="$_bcd_pad_out"
        # W4 header tint + W3 active-column highlight. The line gets a full-width
        # subtle bg (256-color 236); [K paints it to EOL while the bg is live.
        # The active sort column's label is BOLD-WHITE (1;97), the rest bold-dim
        # (2). SGR codes are zero-width so the exact column layout — and the
        # ghost-safe width budget — is untouched. Arrow/direction stays in the
        # footer (sort:col↑) to avoid adding a visible char to the tight header.
        _bcd_hac="$_bcd_ml_sort"; case "$_bcd_hac" in *-desc) _bcd_hac="${_bcd_hac%-desc}" ;; esac
        _bcd_hR="${_bcd_dE}[22;39m"
        __bettercd_hcol name;    _bcd_hnm="$_bcd_hcs$_bcd_thn$_bcd_hR"
        __bettercd_hcol visited; _bcd_hvi="${_bcd_hcs}visited$_bcd_hR"
        __bettercd_hcol modified;_bcd_hmd="${_bcd_hcs}modified$_bcd_hR"
        __bettercd_hcol created; _bcd_hct="${_bcd_hcs}created$_bcd_hR"
        __bettercd_hcol version; _bcd_hvr="${_bcd_hcs}version$_bcd_hR"
        __bettercd_hcol ship;    _bcd_hsh="${_bcd_hcs}ship$_bcd_hR"
        __bettercd_hcol size;    _bcd_hsz="${_bcd_hcs}size$_bcd_hR"
        _bcd_df="$_bcd_df${_bcd_dE}[48;5;236m  $_bcd_hnm $_bcd_hvi  $_bcd_hmd    $_bcd_hct     $_bcd_hvr    $_bcd_hsh  $_bcd_hsz${_bcd_dE}[K${_bcd_dE}[0m$_bcd_dL"
    elif [ -n "$_bcd_ml_query" ]; then
        _bcd_df="$_bcd_df${_bcd_dE}[38;5;213m✻${_bcd_dE}[0m ${_bcd_dE}[2mrecent places · $_bcd_ml_n/${_bcd_ml_basen:-0}${_bcd_dE}[0m${_bcd_dE}[K$_bcd_dL"
    else
        _bcd_df="$_bcd_df${_bcd_dE}[38;5;213m✻${_bcd_dE}[0m ${_bcd_dE}[2mrecent places${_bcd_dE}[0m${_bcd_dE}[K$_bcd_dL"
    fi
    _bcd_di=0; _bcd_dend=$(( _bcd_ml_off + _bcd_ml_vis )); _bcd_demit=0
    while IFS= read -r _bcd_drow; do
        [ -n "$_bcd_drow" ] || continue
        if [ "$_bcd_di" -ge "$_bcd_ml_off" ] && [ "$_bcd_di" -lt "$_bcd_dend" ]; then
            _bcd_drp="${_bcd_drow%%"$_BETTERCD_TAB"*}"
            _bcd_drest="${_bcd_drow#*"$_BETTERCD_TAB"}"
            _bcd_ddisp="${_bcd_drest%%"$_BETTERCD_TAB"*}"
            _bcd_dext="${_bcd_drest##*"$_BETTERCD_TAB"}"
            __bettercd_meta_c "$_bcd_drp"
            case "$_bcd_c_git" in
                clean) _bcd_dcol=40 ;;
                mod)   _bcd_dcol=178 ;;
                untr)  _bcd_dcol=208 ;;
                *)     _bcd_dcol="" ;;
            esac
            if __bettercd_is_pinned "$_bcd_drp"; then _bcd_dgut="$_bcd_g_pin"
            elif [ "$_bcd_dext" = 1 ]; then _bcd_dgut="$_bcd_g_found"
            elif [ "$_bcd_c_git" = clean ]; then _bcd_dgut="$_bcd_g_clean"
            elif [ "$_bcd_c_git" = mod ]; then _bcd_dgut="$_bcd_g_mod"
            elif [ "$_bcd_c_git" = untr ]; then _bcd_dgut="$_bcd_g_untr"
            elif [ "$_bcd_c_proj" = 1 ]; then _bcd_dgut="$_bcd_g_proj"
            else _bcd_dgut="$_bcd_g_plain"; fi
            _bcd_dbold=""; [ "$_bcd_c_proj" = 1 ] && _bcd_dbold="1;"
            if [ "$_bcd_ml_table" = 1 ]; then
                __bettercd_meta_d "$_bcd_drp"
                _bcd_dship=" -  "
                case "$_bcd_d_ship" in y) _bcd_dship=" ✓  " ;; n) _bcd_dship=" ✗  " ;; esac
                _bcd_tnw=$(( _bcd_ml_cols - 58 )); [ "$_bcd_tnw" -ge 16 ] || _bcd_tnw=16
                __bettercd_pad "$_bcd_ddisp" "$_bcd_tnw"; _bcd_dnm="$_bcd_pad_out"
                __bettercd_pad "$_bcd_d_vis" 8;  _bcd_dvi="$_bcd_pad_out"
                __bettercd_pad "$_bcd_d_mt" 11;  _bcd_dmt="$_bcd_pad_out"
                __bettercd_pad "$_bcd_d_crt" 11; _bcd_dct="$_bcd_pad_out"
                __bettercd_pad "$_bcd_d_ver" 10; _bcd_dvr="$_bcd_pad_out"
                _bcd_dtext="$_bcd_dnm $_bcd_dvi $_bcd_dmt $_bcd_dct $_bcd_dvr$_bcd_dship$_bcd_d_sz"
            else
                _bcd_dtext="$_bcd_ddisp"
            fi
            if [ "$_bcd_di" = "${_bcd_ml_flashrow:--1}" ]; then
                # F2: a re-mark of an already-marked dir flashes the row bright
                _bcd_df="$_bcd_df${_bcd_dE}[38;5;${_bcd_dc}m$_bcd_dgut${_bcd_dE}[0m ${_bcd_dE}[7;1;38;5;220m$_bcd_dtext${_bcd_dE}[0m${_bcd_dE}[K$_bcd_dL"
            elif [ "$_bcd_di" = "$_bcd_ml_sel" ]; then
                if [ -n "$_bcd_dcol" ]; then _bcd_dsgr="7;${_bcd_dbold}38;5;${_bcd_dcol}"
                else _bcd_dsgr="7;${_bcd_dbold}36"; fi
                _bcd_df="$_bcd_df${_bcd_dE}[38;5;${_bcd_dc}m$_bcd_dgut${_bcd_dE}[0m ${_bcd_dE}[${_bcd_dsgr}m$_bcd_dtext${_bcd_dE}[0m${_bcd_dE}[K$_bcd_dL"
            else
                if [ "$_bcd_dext" = 1 ]; then _bcd_dsgr="2"
                elif [ -n "$_bcd_dcol" ]; then _bcd_dsgr="${_bcd_dbold}38;5;${_bcd_dcol}"
                elif [ -n "$_bcd_dbold" ]; then _bcd_dsgr="1"
                else _bcd_dsgr="2"; fi
                _bcd_df="$_bcd_df${_bcd_dE}[2m$_bcd_dgut${_bcd_dE}[0m ${_bcd_dE}[${_bcd_dsgr}m$_bcd_dtext${_bcd_dE}[0m${_bcd_dE}[K$_bcd_dL"
            fi
            _bcd_demit=$((_bcd_demit + 1))
        fi
        _bcd_di=$((_bcd_di + 1))
        [ "$_bcd_di" -ge "$_bcd_dend" ] && break
    done <<__BCD_EOF__
$_bcd_ml_rows
__BCD_EOF__
    while [ "$_bcd_demit" -lt "$_bcd_ml_vis" ]; do
        if [ "$_bcd_ml_n" -eq 0 ] && [ "$_bcd_demit" -eq 0 ]; then
            _bcd_df="$_bcd_df${_bcd_dE}[2m  (no matches — esc clears)${_bcd_dE}[0m${_bcd_dE}[K$_bcd_dL"
        else
            _bcd_df="$_bcd_df${_bcd_dE}[K$_bcd_dL"
        fi
        _bcd_demit=$((_bcd_demit + 1))
    done
    _bcd_dup=" "; _bcd_ddn=" "
    [ "$_bcd_ml_off" -gt 0 ] && _bcd_dup="↑"
    [ "$_bcd_dend" -lt "$_bcd_ml_n" ] && _bcd_ddn="↓"
    _bcd_dpos=$(( _bcd_ml_sel + 1 )); [ "$_bcd_ml_n" -eq 0 ] && _bcd_dpos=0
    __bettercd_sort_label
    _bcd_dfoot="$_bcd_dup $_bcd_dpos/$_bcd_ml_n $_bcd_ddn  sort:$_bcd_sortlabel"
    [ "${_bcd_ml_cachenote:-0}" = 1 ] && _bcd_dfoot="$_bcd_dfoot (cached only)"
    [ "$_bcd_ml_preset" != all ] && _bcd_dfoot="$_bcd_dfoot  ▸$_bcd_ml_preset"
    [ "$_bcd_ml_table" = 1 ] && _bcd_dfoot="$_bcd_dfoot  detail"
    _bcd_df="$_bcd_df  ${_bcd_dE}[2m$_bcd_dfoot${_bcd_dE}[0m${_bcd_dE}[K$_bcd_dL"
    # Legend line: the full colored glyph legend fits comfortably at normal
    # widths; on a narrow terminal (where it would wrap into a ghost row) fall
    # back to a compact single-SGR version that is safe to leave whole.
    if [ "$_bcd_ml_cols" -ge 78 ]; then
        _bcd_df="$_bcd_df  ${_bcd_dE}[2m$_bcd_g_pin pinned${_bcd_dE}[0m ${_bcd_dE}[38;5;40m$_bcd_g_clean clean${_bcd_dE}[0m ${_bcd_dE}[38;5;178m$_bcd_g_mod modified${_bcd_dE}[0m ${_bcd_dE}[38;5;208m$_bcd_g_untr untracked${_bcd_dE}[0m ${_bcd_dE}[1m$_bcd_g_proj project${_bcd_dE}[0m ${_bcd_dE}[2m$_bcd_g_found found · bold = .project${_bcd_dE}[0m${_bcd_dE}[K$_bcd_dL"
    else
        _bcd_dleg="$_bcd_g_pin pin $_bcd_g_clean clean $_bcd_g_mod mod $_bcd_g_untr untr $_bcd_g_proj proj $_bcd_g_found found"
        [ "${#_bcd_dleg}" -gt $(( _bcd_ml_cols - 3 )) ] && { __bettercd_pad "$_bcd_dleg" $(( _bcd_ml_cols - 3 )); _bcd_dleg="$_bcd_pad_out"; }
        _bcd_df="$_bcd_df  ${_bcd_dE}[2m$_bcd_dleg${_bcd_dE}[0m${_bcd_dE}[K$_bcd_dL"
    fi
    # Keys line: plain text (one SGR wrapper) → hard-truncate its content to the
    # terminal width so it can never wrap into a ghost row when the window is
    # narrow. Byte length ≥ display width, so the guard errs on the safe side.
    _bcd_dkeys="type=filter · P pin · T mark · V table · S size · R sort · L preset · E icons · click header=sort · ? help"
    [ "${#_bcd_dkeys}" -gt $(( _bcd_ml_cols - 3 )) ] && { __bettercd_pad "$_bcd_dkeys" $(( _bcd_ml_cols - 3 )); _bcd_dkeys="$_bcd_pad_out"; }
    _bcd_df="$_bcd_df  ${_bcd_dE}[2m$_bcd_dkeys${_bcd_dE}[0m${_bcd_dE}[K$_bcd_dL"
    printf '%s' "$_bcd_df" >/dev/tty
}

# The help overlay (F8 `?`): erase the menu, print a key cheat-sheet, wait for
# any key, then let the caller repaint. Drawn as its own modal so it can be
# taller than the menu without disturbing the geometry.
__bettercd_menu_help() {
    _bcd_hE="$_BETTERCD_ESC"; _bcd_hL="$_BETTERCD_CR
"
    # ABSOLUTE from the frame top (not the parked cursor — which sits on the real
    # command line at top-1 in realcmd mode): erase the frame, draw the modal in
    # its place. On close, erase from top again; the caller's fresh-repaint
    # (_bcd_ml_fresh=1) then redraws the frame and re-parks. The command line at
    # top-1 is never touched, so "cd -- <query>" survives the help overlay.
    printf '%s[%d;1H%s[J' "$_bcd_hE" "${_bcd_ml_top:-1}" "$_bcd_hE" >/dev/tty
    printf '%s' "\
${_bcd_hE}[1;36m  ✻ bettercd dropdown — keys${_bcd_hE}[0m${_bcd_hE}[K$_bcd_hL\
${_bcd_hE}[2m  type = filter (live)   ↑↓ move   ⏎/click cd   1-9 pick   G bottom${_bcd_hE}[0m${_bcd_hE}[K$_bcd_hL\
${_bcd_hE}[2m  P pin (float to top, persists)   T mark project (.project/)${_bcd_hE}[0m${_bcd_hE}[K$_bcd_hL\
${_bcd_hE}[2m  V table   R sort   click a header = sort by that column   L preset${_bcd_hE}[0m${_bcd_hE}[K$_bcd_hL\
${_bcd_hE}[2m  S size   E icons↔emoji   U parent   F full/home path${_bcd_hE}[0m${_bcd_hE}[K$_bcd_hL\
${_bcd_hE}[2m  O reveal in Finder   esc clears query / cancels${_bcd_hE}[0m${_bcd_hE}[K$_bcd_hL\
${_bcd_hE}[2m  ⚑pin ●clean ◐modified ○untracked ▪project +found${_bcd_hE}[0m${_bcd_hE}[K$_bcd_hL\
${_bcd_hE}[38;5;213m  press any key${_bcd_hE}[0m${_bcd_hE}[K$_bcd_hL" >/dev/tty
    __bettercd_readkey ""
    printf '%s[%d;1H%s[J' "$_bcd_hE" "${_bcd_ml_top:-1}" "$_bcd_hE" >/dev/tty
}

# W6' idle tick. The primary read wakes on a timeout while the menu is idle and
# calls this — ONE stty fork BETWEEN keys, never on a keystroke, so the zero-fork
# keystroke budget is untouched. This closes the zsh resize gap within the law:
# zsh never delivers a WINCH to a raw-read loop, but polling the tty size on an
# idle tick catches a resize within ~2s (bash also keeps its next-key reflow).
# On a width/height change: reflow via the absolute full-redraw path + re-measure
# (a narrower width wraps lines and moves the anchor). Returns 1 only if the tty
# vanished (stty fails), so the loop cancels instead of spinning on EOF.
__bettercd_menu_tick() {
    _bcd_tk_sz="$(command stty size </dev/tty 2>/dev/null)"
    [ -n "$_bcd_tk_sz" ] || return 1
    case "$_bcd_tk_sz" in
        *[0-9]' '[0-9]*)
            _bcd_tk_r="${_bcd_tk_sz%% *}"; _bcd_tk_c="${_bcd_tk_sz#* }"
            if [ "$_bcd_tk_c" != "$_bcd_ml_cols" ] || [ "$_bcd_tk_r" != "${_bcd_ml_termh-}" ]; then
                _bcd_ml_cols="$_bcd_tk_c"; _bcd_ml_termh="$_bcd_tk_r"
                case "$_bcd_tk_r" in ''|*[!0-9]*) ;; *) LINES="$_bcd_tk_r" ;; esac
                __bettercd_menu_geom
                printf '\033[%d;1H\033[J' "${_bcd_ml_top:-1}" >/dev/tty
                __bettercd_menu_draw; __bettercd_menu_measure; __bettercd_menu_park
                _bcd_ml_plines="$_bcd_ml_lines"; _bcd_ml_psel="$_bcd_ml_sel"; _bcd_ml_poff="$_bcd_ml_off"
            fi
            ;;
    esac
    # W7b: once the armed query has settled for a tick, launch the detached
    # search; while it runs, ingest new results and repaint in place.
    if [ -n "${_bcd_ml_streamwant-}" ] && [ -z "${_bcd_ml_job-}" ] \
       && [ "$_bcd_ml_streamwant" = "$_bcd_ml_query" ]; then
        __bettercd_stream_start "$_bcd_ml_query"; _bcd_ml_streamwant=""
    fi
    if [ -n "${_bcd_ml_job-}" ]; then
        if __bettercd_stream_ingest; then
            printf '\033[%d;1H' "${_bcd_ml_top:-1}" >/dev/tty
            __bettercd_menu_draw; __bettercd_menu_park
        fi
        command kill -0 "$_bcd_ml_job" 2>/dev/null || __bettercd_stream_reap
    fi
    return 0
}



# The interactive loop: raw single-byte input, redraw in place, clean erase.
# stty is restored before EVERY return path (trap-free by design).
# Measure the menu's top row (one CPR round-trip) so mouse clicks map to rows.
# Called at open and after any redraw that changes the block's height.
__bettercd_menu_measure() {
    _bcd_ml_top=""
    printf '\033[6n' >/dev/tty
    _bcd_ml_rep=""; _bcd_ml_i=0
    while [ "$_bcd_ml_i" -lt 12 ]; do
        __bettercd_readkey 0.2
        [ -n "$_bcd_key" ] || break
        [ "$_bcd_key" = R ] && break
        _bcd_ml_rep="$_bcd_ml_rep$_bcd_key"
        _bcd_ml_i=$((_bcd_ml_i + 1))
    done
    _bcd_ml_rep="${_bcd_ml_rep##*\[}"; _bcd_ml_rep="${_bcd_ml_rep%%;*}"
    case "$_bcd_ml_rep" in
        ''|*[!0-9]*) ;;
        *) _bcd_ml_top=$(( _bcd_ml_rep - _bcd_ml_lines )) ;;
    esac
    # W1' realpark: only paint the query onto the REAL command line when that
    # line is actually ON SCREEN (top>=2 → command at top-1>=1). If the frame
    # scrolled it off the top (top<=1, tiny window), fall back to the on-frame
    # ⌕ echo so the query never lands on a blank spacer that looks like a wiped
    # command line. The geom above reserves a row to keep this the rare case.
    _bcd_ml_realpark=0
    if [ "${_bcd_ml_pmode:-fallback}" = realcmd ] && [ -n "${_bcd_ml_top:-}" ] && [ "$_bcd_ml_top" -ge 2 ]; then
        _bcd_ml_realpark=1
    fi
}

# W1' park. realcmd: PAINT the typed query (bold-cyan) onto the REAL command
# line — row top-1, starting at _bcd_ml_qcol (prompt + "cd -- " + a blank) —
# and \033[K clears any stale tail; the paint leaves the cursor parked at the
# query's end, so this both draws and parks in one move. fallback: park at the
# end of the on-frame ⌕ echo (spacer row = top). Absolute from the measured top;
# only the pre-measure first frame uses the relative form.
__bettercd_menu_park() {
    if [ "${_bcd_ml_realpark:-0}" = 1 ] && [ -n "${_bcd_ml_top:-}" ]; then
        printf '\033[%d;%dH\033[1;36m%s\033[0m\033[K' \
            "$(( _bcd_ml_top - 1 ))" "$_bcd_ml_qcol" "$_bcd_ml_query" >/dev/tty
    elif [ -n "${_bcd_ml_top:-}" ]; then
        printf '\033[%d;%dH' "$_bcd_ml_top" "$(( 5 + ${#_bcd_ml_query} ))" >/dev/tty
    else
        printf '\033[%dA\033[%dG' "$_bcd_ml_lines" "$(( 5 + ${#_bcd_ml_query} ))" >/dev/tty
    fi
}

# Rebuild the view after a state change (sort/preset/pins/query/full-path), then
# keep the selection glued to the same item it was on. $1 = "A" to also rebuild
# the (rarer) base list; anything else rebuilds only the filtered rows.
__bettercd_menu_rebuild() { # $1 = A|B
    _bcd_ml_curp="$(__bettercd_nthline "$_bcd_ml_list" "$_bcd_ml_sel")"
    [ "$1" = A ] && __bettercd_menu_stageA
    _bcd_ml_qsrc="$_bcd_ml_base"       # a base/preset/sort change filters the WHOLE base…
    __bettercd_qstk_reset              # …and invalidates the per-prefix query stack
    __bettercd_menu_stageB
    [ -n "$_bcd_ml_curp" ] && __bettercd_menu_reselect "$_bcd_ml_curp"
    __bettercd_menu_geom
    _bcd_ml_rebuild=1
}

# W7 query-stack: a per-prefix-length cache of the filtered view, so appending a
# char filters only the previous (smaller) match set and backspace is a pure POP
# with ZERO recompute. Levels are delimited by GS (never present in a path).
__bettercd_qstk_reset() {
    _bcd_ml_stk_rows=""; _bcd_ml_stk_list=""; _bcd_ml_stk_match=""; _bcd_ml_stk_n=""
}
# Append a character: push the current level, then filter the previous prefix's
# matched subset (not the whole base) by the now-longer query.
__bettercd_qfwd() {
    _bcd_ml_curp="$(__bettercd_nthline "$_bcd_ml_list" "$_bcd_ml_sel")"
    _bcd_ml_stk_rows="$_bcd_ml_stk_rows$_BETTERCD_GS$_bcd_ml_rows"
    _bcd_ml_stk_list="$_bcd_ml_stk_list$_BETTERCD_GS$_bcd_ml_list"
    _bcd_ml_stk_match="$_bcd_ml_stk_match$_BETTERCD_GS${_bcd_ml_qmatched-}"
    _bcd_ml_stk_n="$_bcd_ml_stk_n $_bcd_ml_n"
    _bcd_ml_qsrc="${_bcd_ml_qmatched-}"
    __bettercd_menu_stageB
    [ -n "$_bcd_ml_curp" ] && __bettercd_menu_reselect "$_bcd_ml_curp"
    __bettercd_menu_geom
    _bcd_ml_rebuild=1
}
# Backspace: POP the cached shorter-prefix level (instant); if the stack was
# invalidated meanwhile, fall back to a full re-filter from the base.
__bettercd_qback() {
    _bcd_ml_curp="$(__bettercd_nthline "$_bcd_ml_list" "$_bcd_ml_sel")"
    case "$_bcd_ml_stk_rows" in
        *"$_BETTERCD_GS"*)
            _bcd_ml_rows="${_bcd_ml_stk_rows##*"$_BETTERCD_GS"}"
            _bcd_ml_stk_rows="${_bcd_ml_stk_rows%"$_BETTERCD_GS"*}"
            _bcd_ml_list="${_bcd_ml_stk_list##*"$_BETTERCD_GS"}"
            _bcd_ml_stk_list="${_bcd_ml_stk_list%"$_BETTERCD_GS"*}"
            _bcd_ml_qmatched="${_bcd_ml_stk_match##*"$_BETTERCD_GS"}"
            _bcd_ml_stk_match="${_bcd_ml_stk_match%"$_BETTERCD_GS"*}"
            _bcd_ml_n="${_bcd_ml_stk_n##* }"
            _bcd_ml_stk_n="${_bcd_ml_stk_n% *}"
            ;;
        *)
            _bcd_ml_qsrc="$_bcd_ml_base"; __bettercd_menu_stageB
            ;;
    esac
    [ -n "$_bcd_ml_curp" ] && __bettercd_menu_reselect "$_bcd_ml_curp"
    __bettercd_menu_geom
    _bcd_ml_rebuild=1
}

# The interactive loop: raw single-byte input, a row model that pins / filters /
# sorts / marks / colors, redraw in place, clean erase. stty is restored before
# EVERY return path (trap-free by design).
# Sticky prefs (view/sort/preset/icons) — ~/.config/bettercd/prefs, flat
# key=value lines, loaded at menu open, saved atomically on change.
__bettercd_prefs_file() { printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/bettercd/prefs"; }
__bettercd_prefs_load() {
    _bcd_pf="$(__bettercd_prefs_file)"
    [ -f "$_bcd_pf" ] || return 0
    while IFS= read -r _bcd_pl; do
        case "$_bcd_pl" in
            table=1) _bcd_ml_table=1 ;;
            sort=*)
                # tolerant loader: accept any known column-sort token, else fall
                # back to recent (so an older/newer prefs file never breaks).
                case "${_bcd_pl#sort=}" in
                    name|name-desc|modified|modified-desc|visited|visited-desc|created|created-desc|version|version-desc|ship|ship-desc|size|size-desc)
                        _bcd_ml_sort="${_bcd_pl#sort=}" ;;
                    *) _bcd_ml_sort=recent ;;
                esac ;;
            preset=proj) _bcd_ml_preset=proj ;;
            preset=git) _bcd_ml_preset=git ;;
            preset=pinned) _bcd_ml_preset=pinned ;;
            emoji=1) _BETTERCD_EMOJI=1 ;;
        esac
    done < "$_bcd_pf"
    return 0
}
__bettercd_prefs_save() {
    _bcd_pf="$(__bettercd_prefs_file)"
    command mkdir -p "${_bcd_pf%/*}" 2>/dev/null || return 0
    {
        printf 'table=%s\n' "${_bcd_ml_table:-0}"
        printf 'sort=%s\n' "${_bcd_ml_sort:-recent}"
        printf 'preset=%s\n' "${_bcd_ml_preset:-all}"
        printf 'emoji=%s\n' "${_BETTERCD_EMOJI:-0}"
    } > "$_bcd_pf.tmp" 2>/dev/null && command mv -f "$_bcd_pf.tmp" "$_bcd_pf" 2>/dev/null
    return 0
}

# Icon set — `e` toggles unicode glyphs ↔ emoji (persisted). Emoji are
# double-width, so EVERY gutter in emoji mode is an emoji (uniform columns).
__bettercd_glyphs() {
    if [ "${_BETTERCD_EMOJI-0}" = 1 ]; then
        _bcd_g_pin="📌"; _bcd_g_clean="🟢"; _bcd_g_mod="🟡"; _bcd_g_untr="🟠"
        _bcd_g_proj="📦"; _bcd_g_found="🔍"; _bcd_g_plain="▫️"
    else
        _bcd_g_pin="⚑"; _bcd_g_clean="●"; _bcd_g_mod="◐"; _bcd_g_untr="○"
        _bcd_g_proj="▪"; _bcd_g_found="+"; _bcd_g_plain="·"
    fi
}

__bettercd_menu_loop() { # $1 = raw pool (real paths, OLDPWD first), $2 count (unused)
    _bcd_ml_pool="$1"
    _bcd_ml_sel=0; _bcd_ml_frame=0; _bcd_ml_off=0
    _bcd_ml_psel=-1; _bcd_ml_poff=-1; _bcd_ml_plines=0
    _bcd_ml_sort=recent; _bcd_ml_preset=all; _bcd_ml_query=""
    _bcd_ml_table=0; _bcd_ml_full=0; _bcd_ml_flashrow=-1; _bcd_ml_cachenote=0
    # a menu open is its own freshness proof: never queue the toast here, and
    # KILL any armed toast-eraser/animator — their delayed ESC7/ESC8 save/
    # restore firing mid-menu corrupts the parked cursor (observed live; the
    # failing repros always followed an autoreload toast, clean runs never did)
    _BETTERCD_UPD_PENDING=""
    __bettercd_anim_kill
    __bettercd_prefs_load
    __bettercd_glyphs
    __bettercd_visits_load
    _BETTERCD_MENU_NOW="$(date +%s 2>/dev/null)"
    # Authoritative terminal width at open — one stty fork (open is NOT the hot
    # path). COLUMNS can be unset (e.g. a bare `zsh -f`) or stale, so trust the
    # real tty size first, then COLUMNS, then a safe default.
    _bcd_ml_cols=""; _bcd_ml_termh=""
    _bcd_ml_wsz="$(command stty size </dev/tty 2>/dev/null)"
    case "$_bcd_ml_wsz" in *[0-9]' '[0-9]*) _bcd_ml_cols="${_bcd_ml_wsz#* }"; _bcd_ml_termh="${_bcd_ml_wsz%% *}" ;; esac
    case "${_bcd_ml_cols:-}" in ''|*[!0-9]*) _bcd_ml_cols="${COLUMNS:-100}" ;; esac
    # W1' park mode: on zsh with a measurable prompt width AND a known invoking
    # command, park the typed query onto the REAL command line ("cd -- <q>").
    # Otherwise (bash, unmeasurable/oversized prompt, no invoke text) fall back
    # to the honest on-frame ⌕ echo. _bcd_ml_qcol = 1-based column where the
    # query starts on the command line (prompt + "cd -- " + one blank).
    _bcd_ml_cmdw="${#_bcd_invoke}"
    __bettercd_prompt_width
    _bcd_ml_pmode=fallback; _bcd_ml_qcol=0
    # best source: the MEASURED cursor cell captured at Enter-time by the
    # zle-line-finish hook — exact under dynamic/transient prompts (p10k etc.)
    # where a static PS1-width calc lies. Single-use; falls back to the calc.
    case "${_BETTERCD_CMD_END_COL-}" in
        ''|*[!0-9]*) ;;
        *)
            _bcd_ml_qcol=$(( _BETTERCD_CMD_END_COL + 1 ))
            [ "$_bcd_ml_qcol" -lt $(( _bcd_ml_cols - 4 )) ] && _bcd_ml_pmode=realcmd ;;
    esac
    _BETTERCD_CMD_END_COL=""
    if [ "$_bcd_ml_pmode" = fallback ] && [ -n "${ZSH_VERSION-}" ] && [ -n "${_bcd_pw:-}" ] && [ -n "${_bcd_invoke:-}" ]; then
        _bcd_ml_qcol=$(( _bcd_pw + _bcd_ml_cmdw + 2 ))
        [ "$_bcd_ml_qcol" -lt $(( _bcd_ml_cols - 4 )) ] && _bcd_ml_pmode=realcmd
    fi
    _bcd_ml_realpark=0; [ "$_bcd_ml_pmode" = realcmd ] && _bcd_ml_realpark=1  # refined after each measure
    _bcd_ml_ext=""; _bcd_ml_extq=""; _bcd_ml_act=""; _bcd_ml_pick_override=""; _bcd_ml_drain=""
    _bcd_ml_job=""; _bcd_ml_streamwant=""; _bcd_ml_streamf=""; _bcd_ml_streamq=""; _bcd_ml_streamn=0
    _bcd_ml_darwin=0; [ "$(command uname 2>/dev/null)" = Darwin ] && _bcd_ml_darwin=1
    __bettercd_pins_load
    __bettercd_menu_stageA
    _bcd_ml_qsrc="$_bcd_ml_base"; __bettercd_qstk_reset
    __bettercd_menu_stageB   # sets rows/list/n and geometry

    _bcd_ml_st="$(command stty -g </dev/tty 2>/dev/null)"
    [ -n "$_bcd_ml_st" ] || { __bettercd_delegate - && __bettercd_clear_miss; return $?; }
    command stty raw -echo </dev/tty 2>/dev/null
    printf '\033[?1003h\033[?1006h' >/dev/tty
    __bettercd_menu_draw
    __bettercd_menu_measure
    __bettercd_menu_park
    _bcd_ml_plines="$_bcd_ml_lines"; _bcd_ml_psel="$_bcd_ml_sel"; _bcd_ml_poff="$_bcd_ml_off"

    _bcd_ml_esc="$_BETTERCD_ESC"; _bcd_ml_cr="$_BETTERCD_CR"
    _bcd_ml_etx="$(printf '\003')"; _bcd_ml_nl="$(printf '\n')"
    _bcd_ml_bs="$(printf '\177')"; _bcd_ml_bs2="$(printf '\010')"
    while :; do
        _bcd_ml_move=""; _bcd_ml_rebuild=""; _bcd_ml_fresh=""; _bcd_ml_skip=0
        # Read timeout = the tick cadence: a fast 0.15s tick while a disk search
        # is armed/streaming (so its results land promptly), else a slow ~2s idle
        # poll (just enough to catch a terminal resize). A real key returns
        # IMMEDIATELY either way — the timeout never adds keystroke latency.
        if [ -n "${_bcd_ml_job-}" ] || [ -n "${_bcd_ml_streamwant-}" ]; then
            __bettercd_readkey 0.15
        else
            __bettercd_readkey 2
        fi
        _bcd_ml_backspaced=0   # one-shot: only the read immediately after a backspace is exempt
        # EMPTY read = a timeout tick (no keystroke): poll width (W6') + launch/
        # ingest the streaming search (W7b). tick returns 1 only if the tty
        # vanished → cancel, never spin on EOF.
        if [ -z "$_bcd_key" ]; then
            if __bettercd_menu_tick; then continue; fi
            _bcd_ml_act=cancel; break
        fi
        if [ "$_bcd_ml_skip" = 0 ]; then
        case "$_bcd_key" in
            "$_bcd_ml_esc")
                __bettercd_readkey 0.05; _bcd_ml_s1="$_bcd_key"
                __bettercd_readkey 0.05; _bcd_ml_s2="$_bcd_key"
                case "$_bcd_ml_s1$_bcd_ml_s2" in
                    '[A'|'OA') _bcd_ml_move=up ;;
                    '[B'|'OB') _bcd_ml_move=down ;;
                    '[<')
                        # SGR mouse: btn;x;y then M(press)/m(release)
                        _bcd_ml_mb=""; _bcd_ml_mf=""; _bcd_ml_i=0
                        while [ "$_bcd_ml_i" -lt 16 ]; do
                            __bettercd_readkey 0.05
                            [ -n "$_bcd_key" ] || break
                            case "$_bcd_key" in
                                M|m) _bcd_ml_mf="$_bcd_key"; break ;;
                                *)   _bcd_ml_mb="$_bcd_ml_mb$_bcd_key" ;;
                            esac
                            _bcd_ml_i=$((_bcd_ml_i + 1))
                        done
                        _bcd_ml_btn="${_bcd_ml_mb%%;*}"
                        _bcd_ml_my="${_bcd_ml_mb##*;}"
                        _bcd_ml_mx="${_bcd_ml_mb#*;}"; _bcd_ml_mx="${_bcd_ml_mx%%;*}"
                        case "$_bcd_ml_btn$_bcd_ml_mx$_bcd_ml_my" in *[!0-9]*) _bcd_ml_mf="" ;; esac
                        if [ -n "$_bcd_ml_mf" ]; then
                            case "$_bcd_ml_btn" in
                                64) [ "$_bcd_ml_off" -gt 0 ] && _bcd_ml_off=$((_bcd_ml_off - 1)) ;;
                                65) [ "$_bcd_ml_off" -lt $(( _bcd_ml_n - _bcd_ml_vis )) ] && \
                                        _bcd_ml_off=$((_bcd_ml_off + 1)) ;;
                                35) # hover selects the row under the pointer
                                    # rows start at top+2 now (L1 query echo, L2
                                    # context header sit above them), so map -2
                                    if [ -n "$_bcd_ml_top" ]; then
                                        _bcd_ml_ci=$(( _bcd_ml_my - _bcd_ml_top - ${_bcd_ml_rowoff:-2} + _bcd_ml_off ))
                                        if [ "$_bcd_ml_ci" -ge "$_bcd_ml_off" ] && \
                                           [ "$_bcd_ml_ci" -lt $(( _bcd_ml_off + _bcd_ml_vis )) ] && \
                                           [ "$_bcd_ml_ci" -lt "$_bcd_ml_n" ]; then
                                            _bcd_ml_sel="$_bcd_ml_ci"
                                        fi
                                    fi ;;
                                0)
                                    if [ "$_bcd_ml_mf" = M ] && [ -n "$_bcd_ml_top" ]; then
                                        # W3: a click on the L2 column-header row
                                        # (top+1) in table mode sorts by that column
                                        if [ "$_bcd_ml_table" = 1 ] && [ "$_bcd_ml_my" -eq $(( _bcd_ml_top + ${_bcd_ml_rowoff:-2} - 1 )) ]; then
                                            __bettercd_col_resolve "$_bcd_ml_mx" "$_bcd_ml_cols"
                                            if [ -n "$_bcd_col" ]; then
                                                __bettercd_sort_click "$_bcd_col"
                                                __bettercd_prefs_save
                                                __bettercd_menu_rebuild A
                                            fi
                                        else
                                            _bcd_ml_ci=$(( _bcd_ml_my - _bcd_ml_top - ${_bcd_ml_rowoff:-2} + _bcd_ml_off ))
                                            if [ "$_bcd_ml_ci" -ge "$_bcd_ml_off" ] && \
                                               [ "$_bcd_ml_ci" -lt $(( _bcd_ml_off + _bcd_ml_vis )) ] && \
                                               [ "$_bcd_ml_ci" -lt "$_bcd_ml_n" ]; then
                                                _bcd_ml_sel="$_bcd_ml_ci"; _bcd_ml_act=select; _bcd_ml_drain=1
                                            fi
                                        fi
                                    fi ;;
                                2) [ "$_bcd_ml_mf" = M ] && { _bcd_ml_act=cancel; _bcd_ml_drain=1; } ;;
                            esac
                        fi ;;
                    '') # bare ESC: clears an active query first, else cancels
                        if [ -n "$_bcd_ml_query" ]; then
                            _bcd_ml_query=""; _bcd_ml_extq=""; _bcd_ml_ext=""
                            __bettercd_menu_rebuild A
                        else
                            _bcd_ml_act=cancel
                        fi ;;
                    *) ;;
                esac ;;
            "$_bcd_ml_cr"|"$_bcd_ml_nl") _bcd_ml_act=select ;;
            "$_bcd_ml_etx") _bcd_ml_act=cancel ;;
            *)
                # TYPING-FIRST: lowercase letters, [._-], and digits (when a
                # query is already active) append to the query and filter live;
                # commands live on the CAPITALS. Backspace edits; arrows/wheel/
                # hover/⏎/click/Esc move & pick (handled above).
                case "$_bcd_key" in
                    "$_bcd_ml_bs"|"$_bcd_ml_bs2")
                        if [ -n "$_bcd_ml_query" ]; then
                            _bcd_ml_query="${_bcd_ml_query%?}"; _bcd_ml_backspaced=1; __bettercd_qback
                        fi ;;
                    G) _bcd_ml_sel=$((_bcd_ml_n - 1)); _bcd_ml_frame=$((_bcd_ml_frame + 1)) ;;
                    P)  # pin/unpin the selected dir (persists, floats to top)
                        _bcd_ml_curp="$(__bettercd_nthline "$_bcd_ml_list" "$_bcd_ml_sel")"
                        [ -n "$_bcd_ml_curp" ] && __bettercd_pin_toggle "$_bcd_ml_curp"
                        __bettercd_menu_rebuild A ;;
                    T)  # mark the selected dir as a project (.project/)
                        _bcd_ml_curp="$(__bettercd_nthline "$_bcd_ml_list" "$_bcd_ml_sel")"
                        if [ -n "$_bcd_ml_curp" ]; then
                            if __bettercd_project_mark "$_bcd_ml_curp"; then
                                __bettercd_meta_inval "$_bcd_ml_curp"; _bcd_ml_rebuild=1
                            else
                                # already marked → flash the row (absolute jump to
                                # frame top so the command line at top-1 is safe)
                                _bcd_ml_flashrow="$_bcd_ml_sel"
                                printf '\033[%d;1H' "${_bcd_ml_top:-1}" >/dev/tty
                                __bettercd_menu_draw; __bettercd_menu_park; command sleep 0.12
                                _bcd_ml_flashrow=-1; _bcd_ml_psel=-1
                            fi
                        fi ;;
                    V) _bcd_ml_table=$(( 1 - _bcd_ml_table )); _bcd_ml_rebuild=1
                       __bettercd_prefs_save ;;
                    S) # on-demand size of the selection (one du, cached)
                        _bcd_ml_szp="$(__bettercd_nthline "$_bcd_ml_list" "$_bcd_ml_sel")"
                        if [ -n "$_bcd_ml_szp" ]; then
                            _bcd_ml_szk="$(command du -sk "$_bcd_ml_szp" 2>/dev/null)"
                            _bcd_ml_szk="${_bcd_ml_szk%%[!0-9]*}"
                            if [ -n "$_bcd_ml_szk" ]; then
                                if   [ "$_bcd_ml_szk" -ge 1048576 ]; then _bcd_ml_szh="$(( _bcd_ml_szk / 1048576 ))G"
                                elif [ "$_bcd_ml_szk" -ge 1024 ];   then _bcd_ml_szh="$(( _bcd_ml_szk / 1024 ))M"
                                else _bcd_ml_szh="${_bcd_ml_szk}K"; fi
                                __bettercd_meta_d "$_bcd_ml_szp"
                                __bettercd_meta_szset "$_bcd_ml_szp" "$_bcd_ml_szh"
                                _bcd_ml_table=1; _bcd_ml_psel=-2
                            fi
                        fi ;;
                    E) # toggle unicode glyphs vs emoji (persisted)
                       if [ "${_BETTERCD_EMOJI-0}" = 1 ]; then _BETTERCD_EMOJI=0; else _BETTERCD_EMOJI=1; fi
                       __bettercd_glyphs; __bettercd_prefs_save
                       _bcd_ml_psel=-2 ;;
                    R)  # cycle the classic 3 sorts: recent → name → modified
                        # (header-clicks unlock the per-column asc/desc states)
                        case "$_bcd_ml_sort" in
                            recent) _bcd_ml_sort=name ;;
                            name)   _bcd_ml_sort=modified ;;
                            *)      _bcd_ml_sort=recent ;;
                        esac
                        __bettercd_prefs_save
                        __bettercd_menu_rebuild A ;;
                    L)  # cycle preset: all → projects → git → pinned
                        case "$_bcd_ml_preset" in
                            all)  _bcd_ml_preset=proj ;;
                            proj) _bcd_ml_preset=git ;;
                            git)  _bcd_ml_preset=pinned ;;
                            *)    _bcd_ml_preset=all ;;
                        esac
                        __bettercd_prefs_save
                        __bettercd_menu_rebuild B ;;
                    U)  # cd to the PARENT of the selection
                        _bcd_ml_curp="$(__bettercd_nthline "$_bcd_ml_list" "$_bcd_ml_sel")"
                        if [ -n "$_bcd_ml_curp" ]; then
                            _bcd_ml_pick_override="${_bcd_ml_curp%/*}"
                            [ -n "$_bcd_ml_pick_override" ] || _bcd_ml_pick_override="/"
                            _bcd_ml_act=select
                        fi ;;
                    F) _bcd_ml_full=$(( 1 - _bcd_ml_full )); __bettercd_menu_rebuild A ;;
                    O)  # reveal in Finder (macOS only; silent no-op elsewhere)
                        if [ "$_bcd_ml_darwin" = 1 ] && command -v open >/dev/null 2>&1; then
                            _bcd_ml_curp="$(__bettercd_nthline "$_bcd_ml_list" "$_bcd_ml_sel")"
                            [ -n "$_bcd_ml_curp" ] && command open -R "$_bcd_ml_curp" >/dev/null 2>&1
                        fi ;;
                    '?') __bettercd_menu_help; _bcd_ml_fresh=1 ;;
                    /)  ;;   # harmless alias — typing already filters, no need for /
                    [0-9])
                        if [ -n "$_bcd_ml_query" ]; then
                            _bcd_ml_query="$_bcd_ml_query$_bcd_key"; __bettercd_qfwd
                        elif [ "$_bcd_key" != 0 ] && [ $(( _bcd_ml_off + _bcd_key )) -le "$_bcd_ml_n" ]; then
                            _bcd_ml_sel=$(( _bcd_ml_off + _bcd_key - 1 )); _bcd_ml_act=select
                        fi ;;
                    [abcdefghijklmnopqrstuvwxyz._-]|' ')
                        # SPACE is a query char (explicit user ask — dirs can have
                        # spaces); lowercase/dots/dashes filter live too.
                        _bcd_ml_query="$_bcd_ml_query$_bcd_key"; __bettercd_qfwd ;;
                    '') _bcd_ml_act=cancel ;;   # EOF
                    *) ;;   # control bytes, unbound capitals → ignore
                esac ;;
        esac
        fi
        if [ "$_bcd_ml_move" = up ] && [ "$_bcd_ml_n" -gt 0 ]; then
            _bcd_ml_sel=$(( (_bcd_ml_sel - 1 + _bcd_ml_n) % _bcd_ml_n ))
            _bcd_ml_frame=$((_bcd_ml_frame + 1))
        elif [ "$_bcd_ml_move" = down ] && [ "$_bcd_ml_n" -gt 0 ]; then
            _bcd_ml_sel=$(( (_bcd_ml_sel + 1) % _bcd_ml_n ))
            _bcd_ml_frame=$((_bcd_ml_frame + 1))
        fi
        # window resized? COLUMNS refreshes when the read returns (the next
        # keypress / mouse event). A width change needs the FULL-redraw path —
        # ESC[J to wipe the reflowed old frame's wrapped remnants, then a
        # RE-MEASURE (a narrower width wraps lines and moves the anchor). Note:
        # a truly keypress-FREE real-time resize is not reachable here — neither
        # zsh nor bash dispatches a WINCH trap to a raw-read loop without a
        # timeout-poll, and zsh never delivers it to a timed raw read at all
        # (verified). So resize reflows on the very next input event.
        if [ "${COLUMNS:-100}" != "$_bcd_ml_cols" ]; then
            _bcd_ml_cols="${COLUMNS:-100}"
            _bcd_ml_fresh=1
        fi
        # W7b: (re)arm or stop the background disk search for the current query
        __bettercd_stream_manage
        [ -n "$_bcd_ml_act" ] && break
        # viewport follows the selection on KEYBOARD moves only — wheel
        # scrolling glides freely without yanking back to the selection
        if [ -n "$_bcd_ml_move" ] || [ "$_bcd_key" = G ]; then
            [ "$_bcd_ml_sel" -lt "$_bcd_ml_off" ] && _bcd_ml_off="$_bcd_ml_sel"
            [ "$_bcd_ml_sel" -ge $(( _bcd_ml_off + _bcd_ml_vis )) ] && \
                _bcd_ml_off=$(( _bcd_ml_sel - _bcd_ml_vis + 1 ))
        fi
        # render, always FROM THE PARKED cursor (L1): a fresh repaint (after a
        # modal) or a height change erases the frame and re-measures; a plain
        # move/content change redraws in place. Every path re-parks the cursor
        # on the query line so typing keeps landing there.
        if [ -n "$_bcd_ml_fresh" ] || [ "$_bcd_ml_lines" != "$_bcd_ml_plines" ]; then
            # height change / fresh repaint: jump ABSOLUTELY to the frame top,
            # erase downward, redraw, RE-MEASURE (reflow may move the anchor), park.
            # Absolute (not \r) so the parked cursor — which sits on the REAL
            # command line at top-1 in realcmd mode — never erases that line.
            printf '\033[%d;1H\033[J' "${_bcd_ml_top:-1}" >/dev/tty
            __bettercd_menu_draw; __bettercd_menu_measure; __bettercd_menu_park
            _bcd_ml_plines="$_bcd_ml_lines"; _bcd_ml_psel="$_bcd_ml_sel"; _bcd_ml_poff="$_bcd_ml_off"
        elif [ "$_bcd_ml_sel" != "$_bcd_ml_psel" ] || [ "$_bcd_ml_off" != "$_bcd_ml_poff" ] \
             || [ -n "$_bcd_ml_rebuild" ]; then
            # same height: jump to frame top and overwrite in place (each drawn
            # line self-clears with [K, so no ESC[J needed), then re-park.
            printf '\033[%d;1H' "${_bcd_ml_top:-1}" >/dev/tty
            __bettercd_menu_draw; __bettercd_menu_park
            _bcd_ml_psel="$_bcd_ml_sel"; _bcd_ml_poff="$_bcd_ml_off"
        fi
    done

    # a mouse CLICK exits on its PRESS, so its trailing release (\e[<..m) is
    # still queued — consume it here, while still in raw mode, or those bytes
    # leak to the shell as junk after we restore cooked mode.
    if [ -n "$_bcd_ml_drain" ]; then
        _bcd_ml_i=0
        while [ "$_bcd_ml_i" -lt 16 ]; do
            __bettercd_readkey 0.06
            [ -n "$_bcd_key" ] || break
            case "$_bcd_key" in m|M) break ;; esac
            _bcd_ml_i=$((_bcd_ml_i + 1))
        done
    fi
    printf '\033[?1006l\033[?1003l' >/dev/tty       # disarm mouse FIRST
    # W1' exit: realcmd → wipe our query appendage off the REAL command line
    # (row top-1 from qcol, keeping "cd --"), then erase the frame from its top;
    # fallback → just erase the frame; pre-measure → relative erase.
    if [ "${_bcd_ml_realpark:-0}" = 1 ] && [ -n "${_bcd_ml_top:-}" ]; then
        printf '\033[%d;%dH\033[K\033[%d;1H\033[J' \
            "$(( _bcd_ml_top - 1 ))" "$_bcd_ml_qcol" "$_bcd_ml_top" >/dev/tty
    elif [ -n "${_bcd_ml_top:-}" ]; then
        printf '\033[%d;1H\033[J' "$_bcd_ml_top" >/dev/tty
    else
        printf '\r\033[J' >/dev/tty
    fi
    __bettercd_stream_stop   # W7b: kill any live search + remove its temp stream
    # Fully drain any bytes still queued in raw mode (a trailing mouse-release
    # from a header/scroll click, an escape tail) so none leak to the cooked
    # shell and nibble the next command's first character. Mouse already disarmed
    # above; bounded so a fast paste can't spin us.
    _bcd_ml_i=0
    while [ "$_bcd_ml_i" -lt 32 ]; do
        __bettercd_readkey 0.02
        [ -n "$_bcd_key" ] || break
        _bcd_ml_i=$((_bcd_ml_i + 1))
    done
    command stty "$_bcd_ml_st" </dev/tty 2>/dev/null # restore BEFORE acting
    if [ "$_bcd_ml_act" = select ]; then
        if [ -n "$_bcd_ml_pick_override" ]; then _bcd_ml_pick="$_bcd_ml_pick_override"
        else _bcd_ml_pick="$(__bettercd_nthline "$_bcd_ml_list" "$_bcd_ml_sel")"; fi
        if [ -n "$_bcd_ml_pick" ]; then
            __bettercd_delegate "$_bcd_ml_pick" && __bettercd_clear_miss
            _bcd_ml_rc=$?
            printf '\033[2m✻ cd %s\033[0m\n' "$(__bettercd_home_rel "$_bcd_ml_pick")" >/dev/tty
            return "$_bcd_ml_rc"
        fi
    fi
    return 1   # cancel
}


# History replay (L2): reconstruct the ordered dirs a user actually stood in,
# from their shell history, by SIMULATING cd across the whole file. One awk
# pass anchors on absolute/~/bare-cd targets and walks relative/.././cd - moves
# textually (mirroring __bettercd_normalize); z/zi/j/pushd and unresolvable cds
# ($()/`…`/vars) blank the simulated cwd until the next anchor. Absolute
# results are emitted in sequence order; a lone relative name that landed while
# the cwd was unknown is emitted as a "?name" marker for the constraint join.
# awk is the right tool here: a single fork over thousands of lines. The -d
# existence checks all happen afterward, in bounded shell loops.
__bettercd_history_replay() { # $1 = history file → newest-first resolved dirs
    # The awk pass does ALL the heavy lifting in-memory (one fork over the whole
    # file): it simulates cd, then emits three labelled sections so the shell
    # loops over hundreds of tiny lists, never thousands. LC_ALL=C: path work is
    # byte-oriented and zsh history is metafied — a UTF-8 locale makes BSD awk
    # choke on invalid multibyte bytes and emit NOTHING. C treats bytes as bytes.
    #   @B  candidate bases (unique resolved abs paths, ≤40) — for the join
    #   @N  unique lone-name markers (≤40)                    — for the join
    #   @L  the resolved dirs, NEWEST-FIRST + deduped (≤300)  — the result stream
    _bcd_bases="$HOME
"
    while IFS= read -r _bcd_bz; do
        [ -n "$_bcd_bz" ] || continue
        case "
$_bcd_bases" in *"
$_bcd_bz
"*) continue ;; esac
        _bcd_bases="$_bcd_bases$_bcd_bz
"
    done <<__BCD_EOF__
${_BETTERCD_SEED_Z-}
__BCD_EOF__

    _bcd_joined=""; _bcd_out=""; _bcd_oc=0; _bcd_sec=""
    while IFS= read -r _bcd_ln; do
        case "$_bcd_ln" in
            @B) _bcd_sec=B; continue ;;
            @N) _bcd_sec=N; continue ;;
            @L) _bcd_sec=L; continue ;;
        esac
        case "$_bcd_sec" in
            B)  # extend the base set with layer-a resolutions (deduped)
                [ -n "$_bcd_ln" ] || continue
                case "
$_bcd_bases" in *"
$_bcd_ln
"*) continue ;; esac
                _bcd_bases="$_bcd_bases$_bcd_ln
" ;;
            N)  # constraint join (L2b): keep a name only if EXACTLY ONE known
                # base has base/name as a real dir (ambiguous → dropped, honest)
                [ -n "$_bcd_ln" ] || continue
                _bcd_hit=""; _bcd_hc=0
                while IFS= read -r _bcd_ba; do
                    [ -n "$_bcd_ba" ] || continue
                    if [ -d "$_bcd_ba/$_bcd_ln" ]; then
                        _bcd_hit="$_bcd_ba/$_bcd_ln"; _bcd_hc=$((_bcd_hc + 1))
                        [ "$_bcd_hc" -ge 2 ] && break
                    fi
                done <<__BCD_INNER__
$_bcd_bases
__BCD_INNER__
                [ "$_bcd_hc" -eq 1 ] && _bcd_joined="$_bcd_joined$_bcd_hit
" ;;
            L)  # truth filter (L2c): substitute/drop markers, keep existing
                # dirs, dedup, stop at the cap (only ~50 ever reach the pool)
                [ "$_bcd_oc" -lt 60 ] || break
                [ -n "$_bcd_ln" ] || continue
                case "$_bcd_ln" in
                    '?'?*)
                        _bcd_nm="${_bcd_ln#?}"; _bcd_ln=""
                        while IFS= read -r _bcd_jj; do
                            case "$_bcd_jj" in */"$_bcd_nm") _bcd_ln="$_bcd_jj"; break ;; esac
                        done <<__BCD_INNER__
$_bcd_joined
__BCD_INNER__
                        [ -n "$_bcd_ln" ] || continue ;;
                esac
                [ -d "$_bcd_ln" ] || continue
                case "
$_bcd_out" in *"
$_bcd_ln
"*) continue ;; esac
                _bcd_out="$_bcd_out$_bcd_ln
"; _bcd_oc=$((_bcd_oc + 1)) ;;
        esac
    done <<__BCD_EOF__
$(LC_ALL=C command awk -v home="$HOME" '
  function norm(base, tgt,   p,n,i,seg,out) {
    if (substr(tgt,1,1) == "/") p = tgt; else p = base "/" tgt
    n = split(p, seg, "/"); out = ""
    for (i = 1; i <= n; i++) {
      if (seg[i] == "" || seg[i] == ".") continue
      else if (seg[i] == "..") sub(/\/[^\/]*$/, "", out)
      else out = out "/" seg[i]
    }
    return (out == "") ? "/" : out
  }
  function rec(v,   nm) {                          # record an emitted value
    em[++ec] = v
    if (substr(v,1,1) == "/") {                    # a resolved path → base
      if (!(v in bseen)) { bseen[v]=1; if (bc<40) bkeep[++bc]=v }
    } else if (substr(v,1,1) == "?") {             # a lone-name marker
      nm = substr(v,2); if (!(nm in nseen)) { nseen[nm]=1; if (nc<40) nkeep[++nc]=nm }
    }
  }
  BEGIN { q = sprintf("%c", 39); known = 0 }
  {
    line = $0
    sub(/^:[[:blank:]][0-9]+:[0-9]+;/, "", line)     # zsh extended prefix
    sub(/^[[:blank:]]+/, "", line); sub(/[[:blank:]]+$/, "", line)
    cmd = line; sub(/[[:blank:]].*$/, "", cmd)
    if (cmd=="z"||cmd=="zi"||cmd=="j"||cmd=="pushd"||cmd=="popd") { known=0; next }
    if (cmd != "cd") next
    if (line == "cd") { old=cwd; cwd=home; known=1; rec(cwd); next }   # bare cd → HOME
    rest = line; sub(/^cd[[:blank:]]+/, "", rest)
    while (rest ~ /^-[A-Za-z]/) sub(/^[^[:blank:]]+[[:blank:]]+/, "", rest)  # flags
    if (substr(rest,1,1)=="\"" && substr(rest,length(rest),1)=="\"" && length(rest)>=2)
      rest = substr(rest, 2, length(rest)-2)
    else if (substr(rest,1,1)==q && substr(rest,length(rest),1)==q && length(rest)>=2)
      rest = substr(rest, 2, length(rest)-2)
    if (rest ~ /[$`]/) { known=0; next }             # var / cmdsub → cannot follow
    if (rest == "-") { if (known && oldk) { t=cwd; cwd=old; old=t; rec(cwd) } else known=0; next }
    if (rest == "--" || rest ~ /^[-+][0-9]/) { known=0; next }   # menu / dir-stack
    if (substr(rest,1,1) == "~") rest = home substr(rest, 2)     # ~ or ~/x
    if (substr(rest,1,1) == "/") { old=cwd; oldk=known; cwd=norm("", rest); known=1; rec(cwd); next }
    if (known) { old=cwd; oldk=known; cwd=norm(cwd, rest); known=1; rec(cwd); next }
    else if (rest !~ /\//) rec("?" rest)             # lone name → join candidate
  }
  END {
    print "@B"; for (i=1;i<=bc;i++) print bkeep[i]
    print "@N"; for (i=1;i<=nc;i++) print nkeep[i]
    print "@L"                                       # newest-first, deduped, ≤300
    for (i=ec;i>=1;i--) { v=em[i]; if (v=="" || (v in lseen)) continue; lseen[v]=1; if (lc<300) { lc++; print v } }
  }
' "$1" 2>/dev/null)
__BCD_EOF__
    printf '%s' "$_bcd_out"
}

# One-time backlog seed for the dropdown: places you went BEFORE this session
# started using bettercd. MERGES two sources (L1): zoxide's db (real visited
# dirs, frecency-ordered — highest recency confidence) FIRST, then history
# replay's resolved dirs that zoxide did not already know. Deduped, pool capped
# ~50, appended AFTER live-session recents so the backlog never outranks what
# the user just did. Runs lazily at first menu build, never at source time.
# _BETTERCD_SEED_Z / _BETTERCD_SEED_H record each entry's source for `places`.
__bettercd_seed_recent() {
    [ -n "${_BETTERCD_SEEDED-}" ] && return 0
    _BETTERCD_SEEDED=1
    _BETTERCD_SEED_Z=""; _BETTERCD_SEED_H=""

    if command -v zoxide >/dev/null 2>&1; then
        _BETTERCD_SEED_Z="$(command zoxide query -l 2>/dev/null | head -100)"
    fi

    _bcd_hres=""
    for _bcd_shf in "${HISTFILE-}" "$HOME/.zsh_history" "$HOME/.bash_history"; do
        [ -f "$_bcd_shf" ] || continue   # empty var fails -f too
        _bcd_hres="$(__bettercd_history_replay "$_bcd_shf")"
        break
    done

    # merge: zoxide first, then history-only, dedup, cap ~200. Pool entries are
    # newline-TERMINATED so the `*"\n<entry>\n"*` membership test delimits every
    # one (including the last) — the same convention the menu builder uses.
    _bcd_pool=""; _bcd_pc=0
    while IFS= read -r _bcd_zl; do
        [ -n "$_bcd_zl" ] || continue
        _bcd_pool="$_bcd_pool$_bcd_zl
"; _bcd_pc=$((_bcd_pc + 1))
    done <<__BCD_EOF__
$_BETTERCD_SEED_Z
__BCD_EOF__
    while IFS= read -r _bcd_hl; do
        [ "$_bcd_pc" -lt 200 ] || break
        [ -n "$_bcd_hl" ] || continue
        case "
$_bcd_pool" in *"
$_bcd_hl
"*) continue ;; esac
        _bcd_pool="$_bcd_pool$_bcd_hl
"
        _BETTERCD_SEED_H="$_BETTERCD_SEED_H$_bcd_hl
"
        _bcd_pc=$((_bcd_pc + 1))
    done <<__BCD_EOF__
$_bcd_hres
__BCD_EOF__

    [ -n "$_bcd_pool" ] || return 0
    _BETTERCD_RECENT="${_BETTERCD_RECENT-}
$_bcd_pool"
    return 0
}

# Build the ordered candidate list — OLDPWD first, then deduped recent+seed
# places that still exist — capped at $1. One source of truth for both the
# dropdown and `bettercd places`. Prints one absolute path per line.
__bettercd_pool() { # $1 = cap
    _bcd_po_cap="$1"; _bcd_po_list=""; _bcd_po_n=0
    if [ -n "${OLDPWD-}" ] && [ -d "$OLDPWD" ]; then
        _bcd_po_list="$OLDPWD
"; _bcd_po_n=1; printf '%s\n' "$OLDPWD"
    fi
    while IFS= read -r _bcd_po_r; do
        [ "$_bcd_po_n" -lt "$_bcd_po_cap" ] || break
        [ -n "$_bcd_po_r" ] || continue
        [ "$_bcd_po_r" = "$PWD" ] && continue
        [ -d "$_bcd_po_r" ] || continue
        case "
$_bcd_po_list" in *"
$_bcd_po_r
"*) continue ;; esac
        _bcd_po_list="$_bcd_po_list$_bcd_po_r
"; _bcd_po_n=$((_bcd_po_n + 1))
        printf '%s\n' "$_bcd_po_r"
    done <<__BCD_EOF__
${_BETTERCD_RECENT-}
__BCD_EOF__
}

# Entry point: build the list (OLDPWD first + deduped recent, cap 10), or fall
# back to a silent classic toggle when there's nothing worth a menu.
__bettercd_magic_menu() { # $1 = "forced" when the user explicitly asked (cd --)
    __bettercd_tty_ok || { __bettercd_delegate - && __bettercd_clear_miss; return $?; }
    __bettercd_seed_recent
    _bcd_mm_list="$(__bettercd_pool 200)"
    _bcd_mm_n=0
    while IFS= read -r _bcd_mm_c; do
        [ -n "$_bcd_mm_c" ] && _bcd_mm_n=$((_bcd_mm_n + 1))
    done <<__BCD_EOF__
$_bcd_mm_list
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

# `bettercd places` (L3): show the whole recent-places pool — numbered,
# home-relative, colored on a tty (NO_COLOR-aware) — with a cheap source tag
# (live / zoxide / history). `bettercd places -n <k>` limits the count.
__bettercd_places() {
    _bcd_pl_cap=1000
    if [ "${1-}" = "-n" ]; then
        case "${2-}" in
            ''|*[!0-9]*) printf 'bettercd: places -n needs a whole number\n' >&2; return 1 ;;
            *) _bcd_pl_cap="$2" ;;
        esac
    fi
    __bettercd_seed_recent
    if [ -t 1 ] && [ -z "${NO_COLOR-}" ] && [ "${TERM-}" != dumb ]; then
        _bcd_pl_N='\033[38;5;213m' _bcd_pl_C='\033[1;36m' _bcd_pl_D='\033[2m' _bcd_pl_R='\033[0m'
    else
        _bcd_pl_N='' _bcd_pl_C='' _bcd_pl_D='' _bcd_pl_R=''
    fi
    _bcd_pl_i=0
    while IFS= read -r _bcd_pl_p; do
        [ -n "$_bcd_pl_p" ] || continue
        _bcd_pl_i=$((_bcd_pl_i + 1))
        _bcd_pl_tag=live
        case "
${_BETTERCD_SEED_Z-}
" in *"
$_bcd_pl_p
"*) _bcd_pl_tag=zoxide ;; esac
        if [ "$_bcd_pl_tag" = live ]; then
            case "
${_BETTERCD_SEED_H-}
" in *"
$_bcd_pl_p
"*) _bcd_pl_tag=history ;; esac
        fi
        printf "  ${_bcd_pl_N}%2d${_bcd_pl_R} ${_bcd_pl_C}%s${_bcd_pl_R}  ${_bcd_pl_D}%s${_bcd_pl_R}\n" \
            "$_bcd_pl_i" "$(__bettercd_home_rel "$_bcd_pl_p")" "$_bcd_pl_tag"
    done <<__BCD_EOF__
$(__bettercd_pool "$_bcd_pl_cap")
__BCD_EOF__
    if [ "$_bcd_pl_i" -eq 0 ]; then
        printf "  ${_bcd_pl_D}no recent places yet — move around a little first${_bcd_pl_R}\n" >&2
        return 1
    fi
    return 0
}

# --- the cd wrapper ----------------------------------------------------------
cd() {
    # zero-fork freshness check; on reload, re-dispatch into the NEW cd
    if __bettercd_interactive && __bettercd_reload_check; then
        cd "$@"
        return $?
    fi
    # fast passthroughs: no args, multiple args, flags, "-", dir-stack refs
    if [ "$#" -ne 1 ]; then
        # bare `cd` on an interactive tty opens the places table (the menu IS
        # the better "where do I want to be"); scripts and non-tty keep the
        # stock go-home exactly. BETTERCD_BARE_MENU=0 restores classic always.
        if [ "$#" -eq 0 ] && [ "${BETTERCD_BARE_MENU-1}" != 0 ] \
           && __bettercd_interactive && __bettercd_tty_ok; then
            _bcd_invoke="cd"
            __bettercd_magic_menu forced
            return $?
        fi
        __bettercd_delegate "$@" && __bettercd_clear_miss
        return $?
    fi
    case "$1" in
        '' )
            __bettercd_delegate "$@" && __bettercd_clear_miss
            return $? ;;
        - )
            # no OLDPWD yet: the builtin would leak "__bettercd_cd:cd: string
            # not in pwd: -" — say it in-brand instead (scripts keep stock)
            if [ -z "${OLDPWD-}" ] && __bettercd_interactive && [ -t 2 ] \
               && [ -z "${NO_COLOR-}" ] && [ "${TERM-}" != dumb ]; then
                printf '\033[38;5;213m✻\033[0m \033[2mnowhere to go back to yet — this shell hasn'"'"'t changed dirs\033[0m\n' >&2
                return 1
            fi
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
                            _bcd_invoke="cd -"   # W1': park the query after the real command
                            __bettercd_magic_menu
                            return $?
                        fi
                    fi ;;
            esac
            __bettercd_delegate "$@" && __bettercd_clear_miss
            return $? ;;
        --help | -h )
            __bettercd_help
            return 0 ;;
        --version )
            printf 'bettercd %s\n' "$BETTERCD_VERSION"
            return 0 ;;
        --status )   bettercd status;  return $? ;;
        --undo )     bettercd undo;    return $? ;;
        --doctor )   bettercd doctor;  return $? ;;
        --backup )   bettercd backup;  return $? ;;
        --places )   bettercd places;  return $? ;;
        --magic )    bettercd magic status; return $? ;;
        --update )   bettercd update;  return $? ;;
        --config | --prefs ) bettercd config; return $? ;;
        --* )
            # all-dashes = TIME TRAVEL: `cd --` = 2 dirs back, `cd ---` = 3
            # back, and so on — the dash count is how far back you jump, and
            # repeating it cycles naturally (the dir you leave becomes recent).
            # Scripts/non-tty keep stock behavior (POSIX `cd --` = home).
            # Anything else (--bogus) = unknown flag: never a dir, never raw.
            case "$1" in
                *[!-]*)
                    if [ -t 2 ] && [ -z "${NO_COLOR-}" ] && [ "${TERM-}" != dumb ]; then
                        printf '\033[38;5;213m✻\033[0m \033[2munknown flag\033[0m \033[1;36m%s\033[0m \033[2m— try\033[0m \033[1mcd --help\033[0m\n' "$1" >&2
                    else
                        printf 'bettercd: unknown flag %s — try cd --help\n' "$1" >&2
                    fi
                    return 1 ;;
            esac
            if __bettercd_interactive; then
                __bettercd_njump "${#1}"
                return $?
            fi
            __bettercd_delegate "$@" && __bettercd_clear_miss
            return $? ;;
        ... | ....* )
            # dot-runs WITH a space (the aliases only catch cd..): cd ... = up 2
            case "$1" in *[!.]*) ;; *)
                _bcd_dots=${#1}; _bcd_dt=".."
                while [ "$_bcd_dots" -gt 2 ]; do _bcd_dt="$_bcd_dt/.."; _bcd_dots=$((_bcd_dots - 1)); done
                __bettercd_delegate "$_bcd_dt" && __bettercd_clear_miss
                return $?
            esac
            __bettercd_delegate "$@" && __bettercd_clear_miss
            return $? ;;
        -* | +* )
            # flags (-P/-L/-e/…) and zsh dir-stack refs (+2/-2): builtin semantics
            __bettercd_cd "$@" && __bettercd_clear_miss
            return $? ;;
    esac

    # happy path: the directory exists — zero-overhead passthrough
    if [ -d "$1" ]; then
        # unenterable dir (no +x): say it in-brand instead of leaking the raw
        # builtin error — one builtin test, hot path stays fork/IO-free
        if [ ! -x "$1" ] && __bettercd_interactive && [ -t 2 ] \
           && [ -z "${NO_COLOR-}" ] && [ "${TERM-}" != dumb ]; then
            printf '\033[38;5;213m✻\033[0m \033[2mcan'"'"'t enter\033[0m \033[1;36m%s\033[0m \033[2m— permission denied\033[0m\n' "$1" >&2
            return 1
        fi
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
        if __bettercd_tty_ok; then
            printf '\033[38;5;213m✻\033[0m \033[2mcreate\033[0m \033[1;36m%s\033[0m \033[2m?\033[0m \033[1m[y/N]\033[0m ' \
                "$(__bettercd_home_rel "$_bcd_norm")" >&2
        else
            printf 'bettercd: create %s ? [y/N] ' "$_bcd_norm" >&2
        fi
        read -r _bcd_ans
        case "$_bcd_ans" in
            y|Y|yes|YES)
                __bettercd_create_and_cd "$_bcd_norm"
                return $? ;;
            *)
                __bettercd_clear_miss
                if __bettercd_tty_ok; then
                    printf '\033[38;5;213m✻\033[0m \033[2mnot created\033[0m\n' >&2
                else
                    printf 'bettercd: not created.\n' >&2
                fi
                return 1 ;;
        esac
    fi
    _BETTERCD_LAST_MISS="$_bcd_norm"
    if __bettercd_interactive && [ "${BETTERCD_QUIET-0}" != 1 ] && __bettercd_tty_ok; then
        # one in-brand line instead of the raw two-line error
        printf '\033[38;5;213m✻\033[0m \033[1;36m%s\033[0m \033[2mdoesn'"'"'t exist — outside your current dir · repeat to create it\033[0m\n' \
            "$(__bettercd_home_rel "$_bcd_norm")" >&2
    else
        printf 'cd: no such file or directory: %s\n' "$1" >&2
        if __bettercd_interactive && [ "${BETTERCD_QUIET-0}" != 1 ]; then
            printf 'bettercd: outside the current dir — repeat the command to create it.\n' >&2
        fi
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

# W1'' measured park column: at Enter-time (zle-line-finish, AFTER any prior
# widget — e.g. p10k transient prompt — so we measure the FINAL rendered line)
# capture the exact cursor cell right after the typed command via one CPR.
# Gated to `cd -*` buffers: zero cost for every other command. zsh only.
if [ -n "${ZSH_VERSION-}" ]; then
    eval '
    if (( ${+functions[zle-line-finish]} )) && \
       [[ ${functions[zle-line-finish]} != *__bettercd_zlf* ]]; then
        functions[__bettercd_prev_zlf]="${functions[zle-line-finish]}"
    fi
    __bettercd_zlf() {
        (( ${+functions[__bettercd_prev_zlf]} )) && __bettercd_prev_zlf "$@"
        case $BUFFER in
            "cd -"*)
                local _rep="" _ch=""
                printf "\033[6n" > /dev/tty
                while read -s -t 0.2 -k 1 _ch < /dev/tty; do
                    [[ $_ch == R ]] && break
                    _rep+=$_ch
                done
                _rep=${_rep##*\[}
                _BETTERCD_CMD_END_COL=${_rep##*;}
                [[ $_BETTERCD_CMD_END_COL == <-> ]] || _BETTERCD_CMD_END_COL=""
                ;;
        esac
    }
    zle-line-finish() { __bettercd_zlf "$@"; }
    zle -N zle-line-finish 2>/dev/null
    '
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
        update)  __bettercd_update ;;
        config|prefs) __bettercd_config ;;
        places)  shift; __bettercd_places "$@" ;;
        status)  __bettercd_status ;;
        version|--version|-v) printf 'bettercd %s\n' "$BETTERCD_VERSION" ;;
        help|--help|-h|'')    __bettercd_help ;;
        *) printf 'bettercd: unknown command: %s (try: bettercd help)\n' "$1" >&2
           return 1 ;;
    esac
}

# force the autoreload check right now (cd --update)
__bettercd_update() {
    _bcd_upv="$BETTERCD_VERSION"
    if __bettercd_reload_check; then
        return 0   # reload_check already announced the new version
    fi
    if [ -t 2 ] && [ -z "${NO_COLOR-}" ] && [ "${TERM-}" != dumb ]; then
        printf '\033[38;5;213m✻\033[0m \033[2malready fresh —\033[0m \033[1;36m%s\033[0m\n' "$_bcd_upv" >&2
    else
        printf 'bettercd: already fresh — %s\n' "$_bcd_upv" >&2
    fi
    return 0
}

# where everything lives (cd --config)
__bettercd_config() {
    _bcf_d="${XDG_CONFIG_HOME:-$HOME/.config}/bettercd"
    if [ -t 1 ] && [ -z "${NO_COLOR-}" ] && [ "${TERM-}" != dumb ]; then
        printf '\033[38;5;213m✻\033[0m \033[1mbettercd config\033[0m\n'
        printf '  \033[1;36m%-11s\033[0m \033[2m%s\033[0m\n' \
            "source"  "${_BETTERCD_SRC:-unknown}" \
            "prefs"   "$_bcf_d/prefs" \
            "pins"    "$_bcf_d/pins" \
            "stamp"   "$_bcf_d/.loaded" \
            "backups" "$_bcf_d/backups/"
        [ -f "$_bcf_d/prefs" ] && { printf '  \033[2mprefs now:\033[0m '; tr '\n' ' ' < "$_bcf_d/prefs"; printf '\n'; }
    else
        printf 'bettercd config\n  source  %s\n  prefs   %s\n  pins    %s\n  stamp   %s\n' \
            "${_BETTERCD_SRC:-unknown}" "$_bcf_d/prefs" "$_bcf_d/pins" "$_bcf_d/.loaded"
    fi
    return 0
}

__bettercd_help() {
    # colors only on a tty, honoring NO_COLOR; plain text everywhere else
    if [ -t 1 ] && [ -z "${NO_COLOR-}" ] && [ "${TERM-}" != dumb ]; then
        _bh_A='\033[38;5;213m' _bh_B='\033[38;5;219m' _bh_P='\033[38;5;225m'
        _bh_S='\033[1;34m' _bh_C='\033[1;36m' _bh_G='\033[32m' _bh_Y='\033[38;5;178m'
        _bh_O='\033[38;5;208m' _bh_D='\033[2m' _bh_W='\033[1m' _bh_R='\033[0m'
    else
        _bh_A='' _bh_B='' _bh_P='' _bh_S='' _bh_C='' _bh_G='' _bh_Y='' _bh_O='' _bh_D='' _bh_W='' _bh_R=''
    fi
    printf "\n"
    printf "  ${_bh_A}┏┓ ┏━╸╺┳╸╺┳╸┏━╸┏━┓┏━╸╺┳┓${_bh_R}\n"
    printf "  ${_bh_B}┣┻┓┣╸  ┃  ┃ ┣╸ ┣┳┛┃   ┃┃${_bh_R}  ${_bh_D}a better cd — zoxide-aware, auto-mkdir, with undo${_bh_R}\n"
    printf "  ${_bh_P}┗━┛┗━╸ ╹  ╹ ┗━╸╹┗╸┗━╸╺┻┛${_bh_R}  ${_bh_D}v${BETTERCD_VERSION} · one file of shell · zero deps${_bh_R}\n"
    printf "\n"
    printf "  ${_bh_D}cd has two answers: it works, or it wastes your time. This removes the second one.${_bh_R}\n"
    printf "\n  ${_bh_S}THE MOVES${_bh_R}\n"
    printf "    ${_bh_C}%-24s${_bh_R} ${_bh_D}%s${_bh_R}\n" \
        "cd <missing-dir>"  "under cwd → created + entered, ✻ sparkle + press ↑ = undo-cd" \
        "cd sr"             "typo guard: 'did you mean src/ ?' before junk is made" \
        "cd app.py:42:7"    "pasted stack-trace paths just work (→ the file's dir)" \
        "cd.."              "the no-space classic — cd.. cd... cd.... all real" \
        "cd"                "just cd: the ✻ places table (scripts still go home)" \
        "cd -"              "toggle · cd -- = 2 back · cd --- = 3 back · ↶ cycles" \
        "undo-cd"           "go back + remove exactly what was created (rmdir-only)"
    printf "\n  ${_bh_S}THE DROPDOWN${_bh_R}  ${_bh_D}(just cd · your places: live + zoxide + replayed history)${_bh_R}\n"
    printf "    ${_bh_C}%-24s${_bh_R} ${_bh_D}%s${_bh_R}\n" \
        "↑↓ jk · wheel · hover" "move — wheel glides the list, hover grabs" \
        "⏎ / click · 1-9 · esc" "go · pick row · leave" \
        "p · t · v · s · e"     "pin · mark .project/ · table · size-on-demand · icons↔emoji" \
        "r · l · / or type"     "sort · preset filter · blazing fuzzy find (then zoxide+disk)" \
        "u · . · o · g G · ?"   "parent · full paths · reveal · top/bottom · everything"
    printf "    ${_bh_D}glyphs: ⚑ pinned  ${_bh_R}${_bh_G}● clean${_bh_R}  ${_bh_Y}◐ modified${_bh_R}  ${_bh_O}○ untracked${_bh_R}  ${_bh_W}▪ project${_bh_R}  ${_bh_D}+ found · bold = .project${_bh_R}\n"
    printf "\n  ${_bh_S}SELF-CARE${_bh_R}\n"
    printf "    ${_bh_C}%-24s${_bh_R} ${_bh_D}%s${_bh_R}\n" \
        "autoreload"            "every cd checks freshness fork-free — edits apply themselves" \
        "bettercd places"       "the whole pool, numbered + tagged (live/zoxide/history)" \
        "bettercd magic ..."    "on|off|status|window <min> — auto-dropdown on double cd -" \
        "bettercd doctor"       "zoxide / fzf / load-order checks (--fix installs)" \
        "bettercd backup"       "snapshot your cd paradigm + RESTORE.md" \
        "bettercd undo|status"  "revert last create · mode/pending/version"
    printf "\n  ${_bh_S}SAFETY${_bh_R}  ${_bh_D}(the rules that make auto-create sane)${_bh_R}\n"
    printf "    ${_bh_D}· outside your cwd: never silent — fail once, then ✻ [y/N]   · undo is rmdir-only, never rm${_bh_R}\n"
    printf "    ${_bh_D}· scripts get zero prompts, zero magic, stock errors          · zoxide fuzzy jumps always win${_bh_R}\n"
    printf "\n  ${_bh_S}ENV${_bh_R}\n"
    printf "    ${_bh_C}%-24s${_bh_R} ${_bh_D}%s${_bh_R}\n" \
        "BETTERCD_AUTO_CREATE=0" "disable auto-create" \
        "BETTERCD_QUIET=1"       "suppress hints" \
        "BETTERCD_SPARKLE=0"     "disable the animated create line" \
        "BETTERCD_HISTORY_HINT=0" "don't push undo-cd into history" \
        "BETTERCD_CD_TYPOS=0"    "no cd.. aliases (set before sourcing)" \
        "BETTERCD_MAGIC=1"       "cd - twice also opens the dropdown" \
        "BETTERCD_AUTORELOAD=0"  "disable seamless self-updates"
    printf "\n  ${_bh_D}receipts: full suite ×2 shells + dash/sh smokes on every push · ~25µs happy path · MIT${_bh_R}\n"
    printf "  ${_bh_A}✻${_bh_R} ${_bh_D}https://github.com/fire17/bettercd${_bh_R}\n\n"
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
    if [ -t 1 ] && [ -z "${NO_COLOR-}" ] && [ "${TERM-}" != dumb ]; then
        _bst_A='\033[38;5;213m' _bst_C='\033[1;36m' _bst_G='\033[32m' _bst_D='\033[2m' _bst_R='\033[0m'
    else
        _bst_A='' _bst_C='' _bst_G='' _bst_D='' _bst_R=''
    fi
    printf "${_bst_A}✻${_bst_R} ${_bst_C}bettercd ${BETTERCD_VERSION}${_bst_R}\n"
    printf "  ${_bst_D}%-13s${_bst_R} %s\n" "cd mode" "$_BETTERCD_MODE"
    if [ -n "${_BETTERCD_UNDO_CREATED-}" ]; then
        printf "  ${_bst_D}%-13s${_bst_R} %s ${_bst_D}(from %s)${_bst_R}\n" "pending undo" "$_BETTERCD_UNDO_TARGET" "$_BETTERCD_UNDO_FROM"
    else
        printf "  ${_bst_D}%-13s${_bst_R} none\n" "pending undo"
    fi
    printf "  ${_bst_D}%-13s${_bst_R} %s\n" "auto-create" "$([ "${BETTERCD_AUTO_CREATE-1}" = 0 ] && echo off || echo on)"
    printf "  ${_bst_D}%-13s${_bst_R} %s\n" "autoreload" "$([ "${BETTERCD_AUTORELOAD-1}" = 0 ] && echo off || echo "${_bst_G}on${_bst_R} (fork-free)")"
    printf "  ${_bst_D}%-13s${_bst_R} %s\n" "magic cd -" "$([ "${BETTERCD_MAGIC-0}" = 1 ] && echo auto || echo 'off (cd -- opens the dropdown)')"
    _bst_pins=0
    _bst_pf="${XDG_CONFIG_HOME:-$HOME/.config}/bettercd/pins"
    if [ -f "$_bst_pf" ]; then
        while IFS= read -r _bst_l; do [ -n "$_bst_l" ] && _bst_pins=$((_bst_pins + 1)); done < "$_bst_pf"
    fi
    printf "  ${_bst_D}%-13s${_bst_R} %s\n" "pins" "$_bst_pins"
    _bst_rec=0
    while IFS= read -r _bst_l; do [ -n "$_bst_l" ] && _bst_rec=$((_bst_rec + 1)); done <<__BCD_EOF__
${_BETTERCD_RECENT-}
__BCD_EOF__
    printf "  ${_bst_D}%-13s${_bst_R} %s tracked this session ${_bst_D}(cd -- for the full pool)${_bst_R}\n" "places" "$_bst_rec"
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
