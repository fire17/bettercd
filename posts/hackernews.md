# Show HN post (prepared — not yet submitted)

Submit at: https://news.ycombinator.com/submit
URL field: https://github.com/fire17/bettercd

## Title

Show HN: Bettercd – cd that mkdirs where you meant, with undo (zoxide-aware)

## Text

`cd` has two outcomes: it works, or it wastes your time. bettercd removes the second one.

If you cd into a path that doesn't exist but sits under your current directory, it mkdir -p's it and puts you there — printing a one-liner to undo everything (rmdir-only: it will never delete content). If the path is *outside* your cwd it refuses once with a hint, and asks [y/N] only on an immediate identical retry. `..` tricks are normalized first, scripts never get prompts or surprise directories, and a trailing slash means "definitely create it here".

It composes with zoxide instead of replacing it: your fuzzy jumps still win for bare names, your existing cd paradigm (zoxide's --cmd cd, a custom cd function, or plain builtin + CDPATH) is detected at load and delegated to, and `bettercd doctor` checks/installs the zoxide+fzf stack and backs up your setup with restore instructions before touching anything.

It's one file of POSIX-leaning shell, no dependencies, ~25µs overhead on the happy path (one `case` + one `[ -d ]`, no subprocesses). 33 test assertions run against bash and zsh on ubuntu+macos in CI.

Install: `brew install fire17/tap/bettercd` or the curl one-liner in the README.

I'd genuinely like this thread's take on the failure modes of auto-creating dirs on cd — the safety ladder in the README is my current answer (typo-shadowing vs zoxide matches, .. normalization, rmdir-only undo, non-interactive guards), and I'm sure HN can find holes in it.

X/Twitter announcement: <X_POST_URL — fill in after posting>

## Posting notes

- Post the X thread first OR edit this text to drop the X link — HN dislikes dead placeholders.
- Best window: weekday 8–10am ET.
- First comment to add immediately after posting: the "safety design" table from the README, as text.
