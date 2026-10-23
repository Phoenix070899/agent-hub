# The Files column watches only the selected checkout

Decided: 2026-10-22
Status: accepted

Asking for a checkout's files stops the watcher of every other checkout and lets it go.
Coming back to a checkout reads it again with git.
Why: each watched checkout runs three or four git commands on every write inside it, and a day of fan-outs left dozens of closed Workers' worktrees watched.
Keeping recent checkouts warm was rejected: a read takes a fraction of a second, a stale watcher costs on every agent write.
