# Bare `hub` opens the Orchestrator working in this checkout, and `hub a10` opens a named agent

Decided: 2026-10-19
Status: accepted

Supersedes: adr/0006's rule that `hub` without an agent reaches the repo's first Orchestrator; with several Orchestrators on their own worktrees, every terminal got the first one.
`hub` sends the checkout it runs in (the repo's folder, or a worktree's); the daemon starts the Orchestrator whose home is that checkout, else the repo's first, else a new one.
`hub a10` starts or finds agent a10 and attaches to it, through `agent.open`, so it works with a daemon older than this change.
A daemon older than this change ignores the checkout and opens the repo's first Orchestrator, as before.
