# Finished Workers' terminals stayed open after release

Found: 2026-10-16
Where: orchestrator.md (processing worker_done), Orca terminals opened by bin/hub-worker
Fixed in: a883823 Dashboard styling and closing finished Worker terminals

Every settled Worker left its terminal open, so they piled up.
Cause: Orca does not close terminals that hub-worker opened, so a release alone left them open.
Fix: after releasing a settled Worker the Orchestrator closes its terminal with `orca terminal close --terminal <handle>`, unless the human asks to keep it.
Lesson: whoever opens a terminal owns closing it; check what the runtime cleans up instead of assuming release does it.
