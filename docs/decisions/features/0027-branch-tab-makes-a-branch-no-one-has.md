# The Branch tab makes a new branch when none has the name typed

Decided: 2026-10-23
Status: accepted

In Create from's Branch tab, a branch picked from the list wins; else a branch the repo has by exactly the name typed; else the agent works on a new branch by that name, from the base picker, in its own worktree, as features/0011 says.
The name is used as typed, with runs of spaces as "-"; unlike Name, it gets no `feat/` prefix and is not shortened.
The line under the field says so ("No branch fix/x yet. Works on a new branch fix/x from main, in its own worktree.").
Why: typing a branch that did not exist did nothing, and the human had to switch to Name, which renames it.
