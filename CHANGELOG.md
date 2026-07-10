# Changelog

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
