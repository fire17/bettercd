# Changelog

## v0.6.0 — 2026-07-10

- **Magic `cd -`** — a sparkling dropdown of recent places. Hit `cd -` a second
  time (or ≥2× within a minute) and a `✻` menu of where you've been drops in:
  arrows / `j` `k` / digits `1-8` to move, `⏎` to jump, `esc`/`q` to cancel.
  Plain Enter picks `$OLDPWD`, so it stays *exactly* `cd -`. `cd --` opens it
  directly. Recent places are tracked in the existing precmd hook (catches every
  cwd change — our cd, pushd, autocd — zero forks on that hot path); the menu
  dedups, drops `$PWD`, and caps at 8 lazily. Rendered raw-tty with in-place
  redraw + clean erase (stty restored on every exit path, incl. Ctrl-C/Esc);
  interactive-tty + UTF-8 gated, else the plain classic toggle. Non-interactive
  shells and `BETTERCD_MAGIC=0` keep today's `cd -` behavior exactly.
- **`bettercd magic on|off|status|window <minutes>`** — toggle the dropdown and
  set the arm window live in the current shell. `status` shows mode, window,
  time left on an active window, and the recent-places count. Persist with
  `export BETTERCD_MAGIC=0` / `export BETTERCD_MAGIC_WINDOW=600` in your rc.
- Tests: 17 new assertions (64 total × bash + zsh) — the `__bettercd_dash_mode`
  state machine (fresh→classic, two-in-a-row→magic, window persist/refresh/
  override, `BETTERCD_MAGIC=0`), the CLI setters/validation, and regression pins
  that non-interactive `cd -` still toggles and `cd --` still delegates.


## v0.5.0 — 2026-07-10

- `cd..` typo aliases: `cd..` → `cd ..`, `cd...` → `cd ../..`, up to `cd.....`
  (each extra dot = one more level). Aliases, not a command-not-found hook —
  shells run that handler in a subshell where cd can't move the parent
  (verified live before choosing). bash scripts unaffected (non-interactive
  bash never expands aliases). `BETTERCD_CD_TYPOS=0` before sourcing disables.


## v0.4.0 — 2026-07-10

- ↑ history hint: after a create, a synthetic `undo-cd` is pushed into the
  CURRENT shell's in-memory history (zsh `print -s` / bash `history -s`), so
  pressing Up at the fresh prompt offers the revert — the announce line now
  says "press ↑ or run undo-cd". Current shell only by design (undo state is
  session-local; other shells couldn't undo). `BETTERCD_HISTORY_HINT=0` opts out.


## v0.3.1 — 2026-07-10

- Lint: simplify a typo-guard test that newer shellcheck (CI) flags as SC2015;
  behavior identical. (macOS tests were green; ubuntu failed at the lint step.)


## v0.3.0 — 2026-07-10

- **Typo guard** — before auto-creating under cwd, an interactive `cd` checks
  for a close-match sibling directory (same name different case, unique prefix,
  or one edit away — add/drop/substitute/transpose) and asks
  `did you mean src/ ? [Y=jump / c=create <target> / n=abort]` instead of
  silently making a junk dir. Interactive only — scripts/non-tty keep today's
  auto-create exactly (CI-safe); trailing-slash targets skip it (explicit
  create intent); disable with `BETTERCD_TYPO_GUARD=0`.
- **Editor / stack-trace paths** — `cd file.py:42` and `cd file.py:42:7` strip
  the trailing `:line[:col]` and, when the stripped path exists, cd into it
  (dir → enter, file → its parent). Only fires when the raw target is missing
  and the stripped path exists, so a dir literally named `foo:42` is still
  creatable. Works in all modes (zoxide / prev / builtin).
- **Sparkle theming** — `BETTERCD_SPARKLE_GLYPHS` and `BETTERCD_SPARKLE_COLORS`
  (space-separated glyph frames / 256-color codes) customize the create-line
  animation; invalid or empty values fall back to the defaults safely.
- Tests: 11 new assertions (44 total × bash + zsh) covering all three plus the
  regressions — non-interactive auto-create, empty-parent fall-through, and
  themed non-tty output.

## v0.2.2 — 2026-07-10

- Beautiful `bettercd help`: colorized, sectioned (USAGE / COMMANDS / ENV /
  EXAMPLE), tty-only colors honoring NO_COLOR; plain text in scripts/pipes.


## v0.2.1 — 2026-07-10

- Fix: sourcing under bash-in-posix-mode `sh` (e.g. macOS `/bin/sh`) failed —
  posix mode rejects the hyphenated `undo-cd` function name. Skipped there
  (`bettercd undo` still works everywhere). Caught by the brew formula test.
- Tests: the POSIX smoke now runs under BOTH dash and sh (the old `break`
  tested only whichever existed first, which is how this slipped through).

## v0.2.0 — 2026-07-09

- ✨ Sparkle announce: in interactive terminals the create message is now one
  line — `+ auto created & cd to <path> - if you did not mean this - please
  run undo-cd to revert this action` — and its leading `+` sparkles through
  unicode glyphs for ~2s (Claude-Code-style) *after* the prompt is back,
  fully non-blocking. Anchored by CSI 6n cursor report, drawn by a detached
  animator around cursor save/restore; prompt hooks (zsh precmd/preexec,
  bash PROMPT_COMMAND) kill it the moment anything would scroll. Announce is
  deferred to precmd so compound commands (`cd x && make`) anchor exactly,
  even at the bottom of the screen and under multi-line prompts.
- `undo-cd` — new top-level alias for `bettercd undo`.
- `BETTERCD_SPARKLE=0` disables the animation; scripts / non-tty shells keep
  the plain static two-line message (undo one-liner intact).

## v0.1.1 — 2026-07-06

- Silence zoxide's doctor false positive: zoxide ≥0.9.7 warns when anything
  redefines `cd` after `zoxide init` — bettercd does so deliberately and
  delegates faithfully, so it sets `_ZO_DOCTOR=0` in zoxide mode (only if the
  user hasn't set it themselves).
- Tests: pin `XDG_CONFIG_HOME` into the sandbox (CI runners set it globally).

## v0.1.0 — 2026-07-06

Initial release.

- `cd` wrapper: auto-`mkdir -p` for missing paths under cwd, with printed undo one-liner
- `bettercd undo` — return + `rmdir`-only cleanup + zoxide db hygiene
- Outside-cwd safety: fail once with hint, `[y/N]` prompt on identical retry (interactive only)
- Trailing-slash force-create; `cd <file>` → parent dir
- Paradigm detection & delegation: zoxide `--cmd cd` / custom `cd` function / builtin (CDPATH honored)
- `bettercd doctor` (+ `--fix`), `bettercd backup` (+ RESTORE.md), `bettercd status`, `cdi`
- Test suite: 33 assertions × bash + zsh, plus dash smoke test; CI on ubuntu + macos
