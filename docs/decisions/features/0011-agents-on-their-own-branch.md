# An agent can work on its own branch in its own worktree

Decided: 2026-10-19
Status: accepted

A new Orchestrator or Claude Code session can start on an existing branch, or on a new branch from a base branch, so several agents work on different features in one repo without touching each other's files.
An existing branch runs in the checkout that already has it (the repo's own included); otherwise the daemon adds a worktree for it.
A new branch gets a new worktree under the Hub's worktrees folder, named after the branch with "/" as "-".
Without either, the agent works in the repo's own checkout, as before.
The agent's terminal, its multiplexer session, and its Orchestrator prompt all start in that worktree; the prompt tells it which branch it is on.
Closing an agent leaves its worktree and branch in place.
