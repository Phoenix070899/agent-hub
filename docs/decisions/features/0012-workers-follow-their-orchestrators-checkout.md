# Workers follow their Orchestrator's checkout

Decided: 2026-10-19
Status: accepted

Supersedes: features/0006 (its diff base) and features/0007 (where a kept try is merged), because an Orchestrator may now work on its own branch (features/0011).
A Worker started in place works in its Orchestrator's checkout, its worktree when it has one.
A Worker's new worktree branches from its Orchestrator's HEAD, not the repo's.
A Worker's diff is taken against the merge-base with its Orchestrator's HEAD.
Keeping a fan-out try merges its branch into the branch its Orchestrator works on.
