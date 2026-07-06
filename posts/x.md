# X/Twitter launch thread (prepared — not yet posted)

## Tweet 1

cd has two outcomes: it works, or it wastes your time.

bettercd removes the second one.

cd into a folder that doesn't exist → it's created, you're in it, and you get a one-command undo.
Typos outside your cwd? It asks first. zoxide fuzzy jumps? Still win.

https://github.com/fire17/bettercd

## Tweet 2

The safety ladder is the whole product:

• under your cwd → mkdir -p + cd + printed undo
• zoxide match on a bare name → fuzzy jump wins (no typo-mkdir)
• outside cwd → fails once, [y/N] on identical retry
• undo = rmdir only, never deletes content
• scripts: zero prompts, zero surprises

## Tweet 3

One file of pure shell. Zero dependencies. ~25µs per cd (builtin is ~12µs) — no daemons, no hooks, nothing at startup.

bash + zsh, macOS/Linux/WSL, 33 test assertions in CI on both.

brew install fire17/tap/bettercd

## Tweet 4

It also ships a doctor:

bettercd doctor → checks zoxide is installed & working, whether it owns cd, whether fzf fuzzy search is wired up — and --fix backs up your entire cd paradigm (with a RESTORE.md) before installing anything.

## Tweet 5

Show HN thread (come poke holes in the safety model): <HN_POST_URL — fill in after posting>

⭐ https://github.com/fire17/bettercd

## Posting notes

- Post tweet 1–4 as a thread; add tweet 5 once the HN post is live, then edit the HN text's X link.
- Attach to tweet 1: a short terminal recording/gif of `cd new/nested/dir` → hint → `bettercd undo` (asciinema or vhs; see README demo block for the script).
