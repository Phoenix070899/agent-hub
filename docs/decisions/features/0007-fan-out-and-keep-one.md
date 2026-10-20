# A Task can fan out to several Workers; the human keeps one

Decided: 2026-10-19
Status: accepted

`worker.fanout` starts 2 to 5 Workers of one profile on one Task, in parallel, each in its own worktree on `<branch>-<n>`, tied by a fan-out id; profiles that write files are listed first.
The tries report to the Orchestrator on screen, else the repo's first live one.
Only a settled try can be kept.
Keeping one (`worker.pick`) commits what it left uncommitted with the Task's title, merges its branch with `--no-ff` into the repo's current branch, and undoes the merge on conflict, leaving the repo as it was.
The other tries are closed, dismissed from Echo, and their worktrees removed, uncommitted work included; their branches stay; the Orchestrator is told.
