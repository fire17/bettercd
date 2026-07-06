# bettercd

**A better `cd` — zoxide-aware, auto-mkdir, with undo. One file of pure shell, zero dependencies, ~25µs overhead.**

`cd` has two answers: it works, or it wastes your time. `bettercd` removes the second one.

```console
$ cd projects/newapp/src        # …doesn't exist yet
bettercd: created 3 new dir(s) → /home/you/projects/newapp/src
          undo: bettercd undo    (or: cd '/home/you' && rmdir …)

$ cd proj                       # exists in your zoxide history
/home/you/projects/newapp       # fuzzy jump, exactly like before

$ cd /etc/nope                  # outside your cwd — never silently created
cd: no such file or directory: /etc/nope
bettercd: outside the current dir — repeat the command to create it.
$ cd /etc/nope                  # you meant it? ok, ask first:
bettercd: create /etc/nope ? [y/N]
```

## What it does

- **`cd` into a directory that doesn't exist, under your cwd → it's created** (`mkdir -p`) and you're in it — with a printed one-liner to undo everything.
- **`bettercd undo`** — go back where you were and remove *exactly* the directories that were created (uses `rmdir` only: anything that gained content is kept, never deleted).
- **Outside your cwd → never silently created.** First attempt fails with a hint; an immediate identical retry asks `[y/N]`. Scripts and non-interactive shells never get prompts and never get surprise directories.
- **Composes with [zoxide](https://github.com/ajeetdsouza/zoxide), never fights it.** If your `cd` is zoxide-powered (`zoxide init --cmd cd`), fuzzy jumps still win for bare names. A **trailing slash forces creation**: `cd newdir/` means "make it *here*", skipping the fuzzy match.
- **`cd some/file.txt` → jumps to the file's parent directory** instead of erroring.
- **`bettercd doctor`** — checks zoxide is installed and working, whether it owns `cd`, whether fuzzy interactive search (fzf) is available, and that bettercd is loaded in the right order. `--fix` backs up your setup first, then offers to install what's missing.
- **`bettercd backup`** — snapshots your current cd paradigm (your `cd` function, aliases, rc files, zoxide database) plus a `RESTORE.md` with exact steps to return to it.
- Flags (`cd -P`), `cd -`, `CDPATH`, dir-stack (`cd +2`), custom `cd` functions: all preserved and passed through.

## Install

**Homebrew**

```sh
brew install fire17/tap/bettercd
```

**curl** (inspect [install.sh](install.sh) first if you like — it only appends a marked block to your shell rc, after backing it up)

```sh
curl -fsSL https://raw.githubusercontent.com/fire17/bettercd/main/install.sh | sh
```

**Manual** — clone and add to your `~/.zshrc` / `~/.bashrc`, *after* any `zoxide init` line:

```sh
source /path/to/bettercd.sh
```

**zinit / oh-my-zsh** — it ships a `bettercd.plugin.zsh`:

```sh
zinit light fire17/bettercd
```

Then restart your shell and run `bettercd doctor`.

> zoxide and fzf are optional. bettercd works without them (auto-create + undo + safety still apply); `bettercd doctor` will offer to install them for the full fuzzy experience.

## The safety design

Auto-creating directories on `cd` is a footgun if done naively. The rules that keep it safe:

| Situation | Behavior |
|---|---|
| Target exists | plain `cd` (zoxide-aware), zero magic |
| Missing, **under cwd** | create + enter + print undo one-liner |
| Missing, bare name with a zoxide match | **fuzzy jump wins** (no typo-mkdir shadowing your history) |
| Missing, **outside cwd** | fail once with hint → identical retry prompts `[y/N]` |
| `..` tricks (`cd a/../../etc`) | normalized *first* — a path that escapes cwd is treated as outside |
| Non-interactive shell / script | no prompts, no auto-create surprises outside cwd |
| Undo | `rmdir` only — never `rm`; non-empty dirs are kept and reported |
| Undo + zoxide | the created dir is also removed from the zoxide database |
| Your old `cd` | detected at load (zoxide / custom function / builtin) and delegated to — never clobbered |

Escape hatches: `BETTERCD_AUTO_CREATE=0` (disable creation), `BETTERCD_QUIET=1` (no hints), `builtin cd` / `command cd` (bypass entirely).

## Performance

The happy path (directory exists) is one `case` and one `[ -d ]` — no subprocesses, no I/O:

```
wrapper: 36.9µs per cd   builtin: 11.7µs per cd   overhead: ~25µs
```

(zsh 5.9, Apple Silicon.) You could `cd` forty thousand times a second before noticing.

## Commands & options

```
cd <dir>              everything above
bettercd undo         revert the last auto-create (go back + rmdir created chain)
bettercd doctor       health-check zoxide / fzf / load order   (--fix to install)
bettercd backup       snapshot current cd setup + RESTORE.md
bettercd status       mode, pending undo, version
cdi <query>           interactive fuzzy cd (zoxide + fzf)

BETTERCD_AUTO_CREATE=0    disable auto-create
BETTERCD_QUIET=1          suppress hints
```

## Uninstall / restore

Remove the `# >>> bettercd >>>` block (or the `source … bettercd.sh` line) from your rc file and restart your shell. Everything bettercd changed lives between those markers; `bettercd backup` snapshots (in `~/.config/bettercd/backups/`) include your original rc files and a `RESTORE.md`.

## FAQ

**Why not just `mkdir -p x && cd x`?** You already know you should. You'll still type `cd x` first. bettercd makes the failure mode cost zero instead of one round-trip.

**Why not zoxide alone?** zoxide answers "take me to a place I've been". bettercd adds the other half: "take me to a place I'm *about* to make" — and wires both together safely.

**Does it slow down my shell?** ~25µs per cd, nothing at startup, no daemons, no hooks beyond the function itself.

**zoxide's doctor complains that it isn't last in my rc?** It would — bettercd deliberately wraps zoxide's `cd` (and delegates to it faithfully), which is exactly what zoxide's heuristic flags. bettercd silences that one false positive by setting `_ZO_DOCTOR=0` in zoxide mode, unless you've set it yourself.

**What shells?** bash and zsh (macOS, Linux, WSL, Git Bash). The core is POSIX-clean and loads under dash. fish and PowerShell are on the roadmap.

**What about muscle memory on servers without it?** Fair warning: you may come to expect `cd` to create. On bare machines it just fails like it always did — nothing breaks, you just miss it.

## License

[MIT](LICENSE) © [fire17](https://github.com/fire17)
