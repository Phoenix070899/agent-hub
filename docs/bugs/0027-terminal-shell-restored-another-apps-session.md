# A Terminal's shell restored another terminal app's saved session

Found: 2026-10-22
Where: crates/hub/src/daemon.rs (shell)
Fixed in: the change that adds this file

While building plain Terminals (features/0021), a new Terminal's shell came up with another terminal app's saved session restored into it.
Cause: the shell inherited `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, and `TERM_SESSION_ID` from whatever terminal started the daemon, and macOS's zshrc restores that app's session when it sees them.
Fix: the daemon removes those three variables, with the inherited agent markers, from every shell it starts.
Lesson: a shell the daemon starts must not claim to be the terminal app that launched the daemon; strip `TERM_PROGRAM*` and `TERM_SESSION_ID` along with the agent markers (see 0005).
