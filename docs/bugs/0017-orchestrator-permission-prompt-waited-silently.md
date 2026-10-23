# An Orchestrator's own permission prompt waited silently

Found: 2026-10-20
Where: crates/hub/src/daemon.rs (agent screen watcher, needs), app/Sources/HubApp/NeedsInbox.swift
Fixed in: 9ab1b7b Hub: an Orchestrator's own permission prompt is a Need, and Echo notifies it (also 620715d on the other branch)

When the human was looking at another agent or away from Echo, an Orchestrator stopped at a permission prompt and nobody was told.
Cause: the daemon watched Normal sessions' screens for permission prompts but left Orchestrators out.
Fix: every agent's screen is watched, Orchestrators included; the Need has profile "orchestrator", notifies like any other, and Approve and Deny press the key in its terminal (features/0017).
Lesson: every terminal that can stop at a prompt raises a Need; when adding a kind of agent, check it is in every watcher.
