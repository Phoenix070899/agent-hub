# Two hub commands at once could start two Hub Daemons on one state folder

Found: 2026-10-17
Where: crates/hub/src/daemon.rs (run)
Fixed in: 8e1d3ba Add the Hub App (SwiftUI) and keep one Hub Daemon per state folder

When two `hub` commands (or the app and a command) found no daemon at the same moment, both started one, and the second could take the socket from the first.
Cause: the only guard was "can I connect to the socket", which both starters passed before either daemon was listening.
Fix: the daemon takes an exclusive `flock` on `hubd.lock` in the state folder before touching the socket and exits if it cannot; a test starts ten daemons at once and checks that exactly one holds the database.
Lesson: guard a single-instance process with a lock it holds for its whole life, not with a check-then-start on its socket.
