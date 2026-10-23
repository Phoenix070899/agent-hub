# A detached client's writer thread stayed alive as long as its terminal was quiet

Found: 2026-10-22
Where: crates/hub/src/daemon.rs (attach)
Fixed in: the change that adds this file

Each `hub attach` that left a quiet terminal (an idle agent or shell) left a thread and a queue behind in the daemon.
Cause: the writer thread blocked on the output channel, and the channel only closed when the terminal next printed something, which an idle terminal might never do.
Fix: the writer waits at most a second at a time and stops once a `detached` flag says the client has left.
Lesson: a thread that waits on a channel also checks whether its client is gone; never let a thread's life depend on more input arriving.
