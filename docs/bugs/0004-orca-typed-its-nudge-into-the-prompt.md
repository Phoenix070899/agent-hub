# Orca typed its message nudge into the human's prompt

Found: 2026-10-16
Where: orchestrator.md (the background listener's `orca orchestration check` command)
Fixed in: 1706620 Orchestrator: listen for every message type so Orca never types its nudge

Text like "You have N orchestration messages" appeared in the Orchestrator's input box, mixed into whatever the human was typing.
Cause: the listener passed `--types "worker_done,escalation,question"`, and Orca types its nudge into the terminal for any message type no listener covers, such as heartbeat.
Fix: the listener drops `--types` so it covers every type, and a delivery of only heartbeats is acked and the listener restarted at once.
Lesson: nothing may type into the human's terminal on its own; when a runtime does, cover every case that triggers it, and prefer a runtime that never types into terminals (ADR 0004).
