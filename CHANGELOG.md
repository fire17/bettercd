# Changelog

## Unreleased (v0.12.0)

- Flag-shaped mistakes (`cd -.-`, `cd -Z`) now fail in-brand: `✻ -.- — no
  such file or directory` (reason preserved from the builtin, prefix junk and
  the arg echo stripped; scripts keep the raw error). Bonus fix: `cd -P dir`
  and friends now route to the BUILTIN under zoxide mode — the zoxide delegate
  chokes on flags (upstream does too), so multi-arg flag calls just failed.

- **Bare `cd` opens the places table** on an interactive tty (scripts and
  non-tty keep the stock go-home exactly; `BETTERCD_BARE_MENU=0` restores
  classic always). `cd ~` still goes home instantly.
- **Dash-count time travel:** `cd -` stays the classic toggle; `cd --` jumps
  2 distinct dirs back, `cd ---` 3 back, and so on — repeating cycles
  naturally (`✻ ↶2 ~/path` note). Distinctness is per prompt (a compound
  `cd a && cd b` is one hop). Scripts keep POSIX `cd --` = home. The menu is
  no longer on `cd --`.
- The typed-query cursor parks at the TRUE end of your command line —
  measured at Enter-time via a zle-line-finish CPR (chains p10k et al., so
  transient/dynamic prompts are exact; static PS1 math was ~2× off there) —
  and the pre-menu auto-update toast's delayed eraser is killed at menu open
  (its ESC7/ESC8 restore was corrupting the parked cursor, nondeterministically).
- Spacer line removed (the tinted header separates); `Directory` title always
  bold-white; the auto-update toast never shows around a menu open.
- Pretty errors: `cd -` with no history yet → `✻ nowhere to go back to yet`;
  an unenterable dir → `✻ can't enter <dir> — permission denied` (zero-cost
  -x pre-check; scripts keep raw errors).

- The `✻ bettercd auto-updated to <ver>` notice is now a **centered, self-erasing
  toast**: it prints centered on its own line at the next prompt and clears
  itself after 2 seconds. If you run another command first, it simply stays in
  scrollback (the eraser is cancelled, so it can never wipe the wrong line).
  Non-interactive shells keep a plain one-line message.

- **Blazing-fast dropdown filtering.** Typing now filters only the *previous*
  keystroke's match set (which can only shrink), and Backspace is a pure pop of a
  per-prefix cache — zero recompute. Measured on a 200-entry list: forward
  ~6ms/key (was ~20), backspace ~8ms/key, both fork-free on a pure-typing
  keystroke. Backspacing through a long query no longer touches the disk on every
  key (that was the real lag), so retreating a query is instant.

- **The dropdown query now types on your REAL command line.** Instead of a
  separate echoed `cd -- <query>` row, the menu opens with an empty spacer line
  and parks the cursor right after your typed `cd --`, so what you type appears
  bold-cyan *continuing your actual command* (`cd -- myproj`) and filters live.
  Backspace edits it; every exit restores the command line clean. On zsh the
  parking column is computed from your prompt's real display width (multi-line
  prompts use the last line); on bash — or any shell whose prompt width can't be
  measured — it falls back to an honest `⌕ query` echo on the spacer. The whole
  menu now positions absolutely from its measured top, so the help overlay,
  flashes and redraws never disturb the command line above.
- Dropdown width is now read authoritatively from the terminal at open (not just
  `$COLUMNS`), so it renders correctly even when `$COLUMNS` is unset or stale,
  and the footer key-hints truncate to fit — no wrapped "ghost" rows on a narrow
  window. **The open menu now reflows on resize even with no keypress**: while it
  sits idle it polls the terminal size on a ~2s tick (a single `stty` between
  keystrokes — the per-keystroke path stays fork-free), so a resize converges
  within ~2s on both zsh and bash; bash also keeps its instant next-key reflow.
- The dropdown's on-disk search (for queries with few local matches) is now a
  **non-blocking background stream**: a detached search writes results to a temp
  file and they fold in as you keep typing — typing never pauses waiting on the
  disk. Changing the query cancels the stale search; everything is cleaned up on
  exit.
- On exit the dropdown fully drains any pending input, so a trailing mouse-click
  release byte can no longer swallow the first character of your next command.

- Dropdown table header (V) now gets a **subtle full-width tint** and the
  **active sort column's label is bold-white** while the rest read dim — so the
  column you sorted by is obvious at a glance (direction arrow stays in the
  `sort:col↑` footer to keep the header inside its exact width budget). The
  header is byte-for-byte the same width as before — no wrap, no ghost rows.
- **SPACE is now a query character** in the dropdown (directories can contain
  spaces) — it filters live alongside lowercase letters, dots and dashes.
- **Pins float to the top only in the default (recent) order.** Under any
  explicit column sort (name/modified/visited/created/version/ship/size, via the
  `R` key or a header click) pinned dirs take their *true* data rank and keep the
  `⚑` glyph; floating resumes when you return to recent.

- Full long-flag surface for cd: --status --version --undo --doctor --backup
  --places --magic --update --config all route to their features; unknown
  --flags get a ✻ one-liner + --help hint (and can never create a directory).
  Real cd flags (-P/-L/-e, +N stack refs) pass through untouched. bettercd
  status restyled in-brand (mode, undo, autoreload, magic, pins, places);
  new bettercd update (force the freshness check) + bettercd config (where
  everything lives). Spaced dot-runs: cd ... goes up two (was a create-trap).

- `cd --help` (and -h) now prints an awesome-readme-grade help page — box-art
  banner in brand gradient, THE MOVES / THE DROPDOWN / SELF-CARE / SAFETY / ENV
  sections, glyph legend, receipts footer. `bettercd help` = same page. Plain
  text when piped/NO_COLOR.

- SEAMLESS AUTORELOAD: every cd runs a zero-fork freshness check (builtin
  -nt stat + builtin stamp read vs ~/.config/bettercd/.loaded); an edited
  bettercd.sh is re-sourced automatically on your next cd — ✻ auto-updated
  banner, no manual source ever again. BETTERCD_AUTORELOAD=0 opts out;
  scripts never autoreload.
- Dropdown footer: 3 lines — position+sort, a colored glyph/color legend,
  and key tips. Header slimmed. e toggles unicode glyphs ↔ emoji. View,
  sort, preset and icon choices PERSIST (~/.config/bettercd/prefs).

- Outside-cwd flow restyled in-brand: one ✻ line (cyan path, dim prose)
  replaces the raw two-line error; styled [y/N] prompt; scripts/non-tty keep
  the exact previous plain text.

- **The dropdown is now a places workbench.** The `cd --` menu grew a full,
  blazingly-fast row model — every expensive fact (git status, tags, mtime) is
  computed only for rows you actually look at, once, then cached as pure string
  lookups; the hot key loop stays fork-free (measured: 40-dir menu builds in
  ~29 ms, a filter keystroke over 100 dirs in ~9 ms).
  - **`p` pin / unpin** the selected dir. Pins float to the very top (above
    OLDPWD) in pin order, get a distinct `⚑` gutter, and grow the window (12 +
    #pins). They **persist** to `~/.config/bettercd/pins` (one path per line,
    written atomically via temp-file + `mv`), loaded once per menu open.
  - **`t` mark project** — creates a `.project/` directory (with an empty
    `status` file) in the selected dir if absent; if already present it just
    flashes the row (never deletes — it is a marker).
  - **Bold projects** — any row whose dir contains `.project` (dir or file)
    renders bold with a `▪` marker.
  - **Git-state colors** — dirs with `.git` colour their path by porcelain
    state: green `●` clean, yellow `◐` tracked-modifications, orange `○`
    untracked. Precedence: **untracked wins over modified wins over clean**
    (one `git status --porcelain | head -40` per git dir, cheap-gated by
    `[ -d .git ]`, computed lazily as rows scroll into view).
  - **`v` table view** — toggles a detail table: gutter · state icon · name ·
    modified date · version (`.project` `version:` line, else latest git tag) ·
    shipped (`✓`/`✗` from `last_shipped:` vs `version:`).
  - **`r` sort** cycles recent → name (A-Z) → modified (newest first); the
    footer shows the active key. Pins always float above the sort.
  - **`l` preset** cycles all → projects → git → pinned.
  - **`/` or just start typing → fuzzy find.** Case-insensitive subsequence
    match over the pool, live per keystroke, zero forks. If a query stays thin
    (<5 hits, ≥3 chars), a brief typing **pause** extends the search via
    `zoxide query --list` then a bounded `find "$HOME"` — extra hits appended as
    dim `+` rows. `esc` clears the query, a second `esc` cancels.
  - **`?` help overlay**, **`u`** cd to the selection's parent, **`.`** toggle
    full vs home-relative paths, **`o`** reveal in Finder (macOS).
- Fixed a latent number-key bug (`1`-`9` row-jump used an unset variable, so it
  always jumped to the first visible row).
- Robustness: name-sort no longer drops a pool's last entry (unterminated
  command-substitution line), and the table's truncation ellipsis is built via
  `printf` (a raw multibyte literal concatenated into a var is mangled by
  non-interactive bash).
- Menu (earlier in this cycle): fixed 12-row window; wheel smooth-scrolls the
  viewport only (selection stays anchored; footer indicators track position);
  hovering selects the row under the pointer; click still cds, right-click
  cancels.


## v0.10.0 — 2026-07-10

- THE BIG LIST: the dropdown now scrolls — viewport as tall as the terminal
  allows, selection-following, position footer (`3/108 ↓`), g/G jump. Pool
  caps raised: zoxide seed 25→100, merged pool 50→200, menu shows everything.
- MOUSE: wheel scrolls the menu, left-click cds to the clicked row,
  right-click cancels (SGR mouse reporting, armed only while the menu is
  open, disarmed on every exit path; click rows mapped via one cursor-position
  report). Terminals without mouse support are simply unaffected.


## v0.9.0 — 2026-07-10

- The dropdown backlog is now a real **history replay**, not just absolute-cd
  scraping. A single `awk` pass SIMULATES `cd` across the whole history file —
  anchoring on absolute / `~` / bare-`cd` targets and walking relative,
  `.`/`..`, and `cd -` moves textually — so relative history like
  `cd /base` → `cd sub` → `cd ..` → `cd sub2` now resolves to real dirs.
  `z`/`zi`/`j`/`pushd` and unresolvable `cd`s (`$(…)`, backticks, vars) blank
  the simulated cwd until the next anchor. A lone `cd <name>` that landed while
  the cwd was unknown is recovered by a **constraint join**: kept only if
  EXACTLY ONE known base (`$HOME`, the zoxide db, or a resolved path) has
  `base/name` as a real dir (ambiguous → dropped, honestly). Every candidate
  passes a `[ -d ]` truth filter before entering the pool.
- Backlog sources are now **merged**, not either/or: zoxide's db FIRST (highest
  recency confidence), then history-replay dirs zoxide didn't already know —
  deduped, pool capped ~50. This surfaces history-only places zoxide never
  recorded (measured: 23 such dirs on a real 6.3k-line `~/.zsh_history`).
- New `bettercd places` — list the whole recent-places pool, numbered and
  home-relative, colored on a tty (NO_COLOR-aware), with a source tag
  (live / zoxide / history). `bettercd places -n <k>` limits the count.
- The `cd -` / `cd --` dropdown now shows up to **10** rows (was 8); number
  keys 1–9 jump directly.
- Seeding stays one-time and lazy (first menu open); measured ~130 ms on a real
  6.3k-line history and well under that on a synthetic 10k-line one. `awk` runs
  under `LC_ALL=C` — path work is byte-oriented and zsh history is metafied, so
  a UTF-8 locale made BSD awk silently emit nothing on real history files.


## v0.8.1 — 2026-07-10

- Lint: same SC2015 pattern the v0.3.1 patch fixed, reintroduced in the
  history-seed code (newer shellcheck on CI flags it; macOS/local did not).
  Behavior identical.


## v0.8.0 — 2026-07-10

- `cd -` is exactly classic again BY DEFAULT — the auto-magic (second dash
  within 60s → dropdown, refreshing window) is now opt-in via
  `bettercd magic on` / `BETTERCD_MAGIC=1`. `cd --` remains the dropdown's
  home, always.
- The dropdown's first open seeds a one-time backlog of past places: zoxide's
  db when available (real visited dirs, frecency-ordered), else zsh/bash
  history `cd` commands with absolute/~ targets (relative entries are
  unresolvable — the cwd they were typed in is unknown). Lazy: no startup cost.


## v0.7.0 — 2026-07-10

- `cd --` now ALWAYS opens the dropdown (even on first use / thin history;
  zero recent places → a friendly note instead of silently toggling). The
  convention pair: `cd --` = always dropdown, `builtin cd -` = always classic.

- Vanished `cd -` targets get a beautiful answer instead of the delegate's raw
  error. Every visited dir's inode is remembered while it exists (`ls -di`,
  POSIX-portable; one fork per directory change, never per prompt) — inodes
  survive same-filesystem renames/moves, so `mv test test2; cd -` now prints
  `✻ …/test is now …/test2 — taking you there` and follows automatically.
  Not found nearby (deleted, or moved across filesystems): `✻ …/test does not
  exist there anymore (deleted or moved away)`, clean rc 1. Interactive only —
  scripts keep the stock failure exactly. (Windows/PowerShell port note: NTFS
  FileID is the inode equivalent — seam marked in the source.)


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
