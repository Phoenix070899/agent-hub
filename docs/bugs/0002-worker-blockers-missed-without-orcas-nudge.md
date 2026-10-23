# Blocked Workers went unnoticed because Orca's message nudge is best effort

Found: 2026-10-16
Where: orchestrator.md (waiting on Workers), bin/hub-notify, bin/hub-worker, settings/worker.json
Fixed in: 074f551 Surface Worker blockers without relying on Orca's nudge

A Worker sitting at a permission prompt or an idle input box could wait with nobody told, because the Orchestrator only woke when Orca typed "You have N orchestration messages" into it.
Cause: Orca's typed nudge is best effort, and a Worker stuck at a prompt sends no message at all, so nothing reached the Orchestrator.
Fix: the Orchestrator keeps one background `check --wait` listener and runs a worker-list plus screen-read backstop on every wake; a Notification hook (hub-notify) reports permission_prompt and idle_prompt with the Worker's screen.
Lesson: catch blockers twice, from the Worker's screen and from its own hook; never depend on a message the stuck party has to send, or on a nudge typed into a terminal.
