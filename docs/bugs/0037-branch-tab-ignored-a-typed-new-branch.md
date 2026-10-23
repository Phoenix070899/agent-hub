# Typing a branch that did not exist in the Branch tab did nothing

Found: 2026-10-23
Where: app/Sources/HubApp/NewSession.swift, app/Sources/HubApp/CreateFrom.swift, app/Sources/HubCore/Models.swift (branchCreateFrom)
Fixed in: the change that adds this file

In Create from's Branch tab, typing a new branch name and starting did nothing, and the human had to switch to Name, which renames the branch with a prefix.
Cause: the Branch tab only returned a branch picked from the list, so a typed name that matched no branch gave no choice at all.
Fix: `branchCreateFrom` takes a picked branch, else a branch the repo has by exactly the typed name, else a new branch by that name from the base picker in its own worktree; the line under the field says which (features/0027).
Lesson: a field that accepts typing acts on what was typed; when the input matches nothing, do the obvious thing and say so, never silently ignore it.
