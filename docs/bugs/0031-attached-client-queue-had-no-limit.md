# A stopped hub attach made the daemon keep a busy agent's whole output in memory

Found: 2026-10-22
Where: crates/hub/src/pty.rs (subscribe, BACKLOG, output fan-out)
Fixed in: the change that adds this file

A suspended `hub attach` or a hung pane let the daemon's memory grow with every byte a busy agent printed.
Cause: each attached client had an unbounded channel of output chunks, so a client that stopped reading kept everything queued.
Fix: each client's queue holds at most 1024 chunks; a client whose queue is full is dropped and attaches again to a fresh screen (features/0026).
Lesson: every queue to a client is bounded; a slow client is let go, never allowed to stall the producer or grow memory.
