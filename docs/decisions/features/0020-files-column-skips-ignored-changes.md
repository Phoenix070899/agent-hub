# The Files column reads the checkout again only for changes it can show

Decided: 2026-10-22
Status: accepted

While ignored files are hidden, a change only inside folders git ignores (build output in `target/`, `.build/`) does not read the checkout again; any other change still does, within about half a second.
With ignored files shown, every change reads it again, as before.
Git runs with `GIT_OPTIONAL_LOCKS=0`, so the column's own `git status` never touches `.git` and wakes the watcher.
Why: `git status` took `.git/index.lock` on every read, the watcher saw it, and the column read the checkout about twice a second forever, which held Echo at about 45% CPU while idle on a 30,000-file repo; builds caused the same loop through their output folders.
Watching only tracked paths was rejected: new untracked files must still appear.
