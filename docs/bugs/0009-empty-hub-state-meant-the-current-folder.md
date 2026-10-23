# An empty HUB_STATE made the CLI use the current folder while Echo used the default

Found: 2026-10-18
Where: crates/hub/src/paths.rs (state_dir)
Fixed in: 8875f62 Echo: ledger redesign, multiplexer panes, Done reports, quick open

With `HUB_STATE` set but empty, `hub` and Echo talked to different daemons.
Cause: the CLI took an empty `HUB_STATE` as the path "", which is the current folder, while the app read empty as unset and used `~/.agent-hub`.
Fix: `state_dir` treats set-but-empty as unset; a unit test covers None, "" and a real path.
Lesson: read every shared environment variable the same way in the app and the CLI, and treat empty as unset.
