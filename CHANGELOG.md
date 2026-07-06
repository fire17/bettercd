# Changelog

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
