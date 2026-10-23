# Workers started in whatever worktree Orca thought was active, sometimes the home folder

Found: 2026-10-16
Where: bin/hub-worker (resolve_worktree), the Orca-era Worker start
Fixed in: 31d2137 hub-worker: start Workers in the caller's repo, not Orca's active worktree

A Worker started with `--worktree current` could open outside the repo, in the home folder.
Cause: `current` mapped to Orca's `active` selector, which only resolves inside an Orca-managed terminal and otherwise falls back to whichever registered worktree contains the cwd.
Fix: hub-worker resolves the caller's checkout with `git rev-parse --show-toplevel` and passes `path:<checkout>`, registering the repo with Orca first when Orca does not know it.
Lesson: name the folder a Worker or agent works in by an explicit absolute path from git; never rely on a tool's notion of the "active" or current worktree.
