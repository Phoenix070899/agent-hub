# The human reviews a Worker's diff and sends line comments

Decided: 2026-10-19
Status: accepted

`worker.diff` shows a worktree Worker's changes since it branched (merge-base with the main checkout's HEAD), committed and uncommitted, new files included; an in-place Worker shows every uncommitted change, the human's included.
Diffs are cut at 2 MB on a line boundary, and the view says so.
Comments go as one review: to the Worker (typed into its terminal, and the Orchestrator is told) or to the Orchestrator (as a human message it acts on).
Unsent comments are kept per Worker in memory while the human looks elsewhere; they do not survive a quit.
