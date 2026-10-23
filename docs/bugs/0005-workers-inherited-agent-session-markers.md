# Workers inherited Claude Code's session markers from the agent that started the daemon

Found: 2026-10-17
Where: crates/hub/src/daemon.rs (inherited_agent_vars, Worker spawn)
Fixed in: 5310484 Cut over from Orca to the Hub Daemon

A Worker started by a daemon that an agent had launched saved no transcript, so it could not be resumed.
Cause: the daemon passed its whole environment on, including `CLAUDE_CODE_CHILD_SESSION`, which Claude Code reads as "do not save transcripts", and other markers such as `CLAUDECODE` and `ORCA_*`.
Fix: the daemon drops `CLAUDECODE`, `AI_AGENT`, `CLAUDE_CODE_*`, `ORCA_*` and similar variables from every process it starts; a unit test covers the list.
Lesson: a process the daemon starts gets a clean agent environment; strip every inherited agent or terminal session marker before spawning.
