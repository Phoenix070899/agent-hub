# hub attach never saw a resize because macOS dropped the ignored SIGWINCH

Found: 2026-10-21
Where: crates/hub/src/attach.rs (passing resizes on)
Fixed in: 3c4f3b9 Draw terminals with libghostty and run the multiplexer in the pane

While moving `hub attach` from polling the size every 300 ms to waiting for SIGWINCH, `sigwait` never returned, so resizes never reached the agent.
Cause: SIGWINCH is ignored by default, and macOS drops an ignored signal even while it is blocked, so it never became pending for `sigwait`.
Fix: install a handler that does nothing before blocking SIGWINCH, so the signal stays pending and the waiting thread takes it.
Lesson: to `sigwait` on a signal whose default action is ignore, install a no-op handler first; on macOS a blocked but ignored signal is discarded.
