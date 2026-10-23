# Create from works on a branch that already exists instead of making it again

Decided: 2026-10-22
Status: accepted

When Name, Smart, or a GitHub issue picks a new branch name the repo already has, the agent works on that branch where it is checked out: the repo's checkout, or its worktree; only a branch checked out nowhere gets a new worktree.
The daemon decides this in `agent.open`, so every client gets it; the dialog's line says so ("feat/x already exists. Works on feat/x in its worktree.").
Why: making the branch again failed, and the human had to retype it under Branch.
