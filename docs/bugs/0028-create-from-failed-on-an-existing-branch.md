# Create from failed when the new branch name already existed

Found: 2026-10-22
Where: crates/hub/src/daemon.rs (open_agent, `new_branch`), app/Sources/HubApp/CreateFrom.swift
Fixed in: the change that adds this file

When Name, Smart, or a GitHub issue picked a branch name the repo already had, starting the agent failed, and the human had to retype the name under Branch.
Cause: `agent.open` with `new_branch` always ran `git worktree add -b`, which refuses a branch that exists.
Fix: the daemon checks the repo's branches first; an existing branch is worked on where it is checked out (the repo's checkout or its worktree), and only a branch checked out nowhere gets a new worktree; the dialog says so (features/0023).
Lesson: before creating a named thing, look it up and reuse it; decide it in the daemon so every client gets the same answer.
