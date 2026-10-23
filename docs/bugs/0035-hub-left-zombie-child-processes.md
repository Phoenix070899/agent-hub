# hub left zombie processes behind: the daemon it started and a timed-out usage read

Found: 2026-10-22
Where: crates/hub/src/proto.rs (spawn_daemon), crates/hub/src/daemon.rs (run_usage)
Fixed in: the change that adds this file

A long-lived `hub attach --follow` kept a zombie after the daemon it had started exited, and the daemon kept one for each `claude -p /usage` it killed after a minute.
Cause: both spawned a child and never waited on it after it ended or was killed, so the kernel kept its exit status.
Fix: `spawn_daemon` reaps the daemon on a thread, and `run_usage` waits on the child after killing it.
Lesson: every spawned child is waited on, including after `kill`; a long-lived parent reaps on a thread when it does not need the result.
