# A Worker waiting on its own background shell was shown as needing the human

Found: 2026-10-19
Where: crates/hub/src/screen.rs (look), crates/hub/src/daemon.rs (notify, screen watcher)
Fixed in: c037986 Hub: a Worker waiting on its background shell is running, not needs you

A Worker that had started a background command and sat at its input box was raised as an idle blocker under Needs you.
Cause: the screen parser only knew Working and Idle, so "at the input box" read as idle even with "1 shell" in the footer, and Claude's idle_prompt notification was reported as a blocker too.
Fix: a new Look::Waiting matches a shell count in the footer below the input box (not the transcript above it); Waiting counts as running and suppresses idle_prompt while it lasts.
Lesson: idle at the prompt is not the same as waiting on the human; read the footer state Claude Code shows, and only the footer, before raising a blocker.
