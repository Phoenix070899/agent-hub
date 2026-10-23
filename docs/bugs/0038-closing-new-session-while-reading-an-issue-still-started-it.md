# Closing Start a session while it read a GitHub issue still started the agent

Found: 2026-10-23
Where: app/Sources/HubApp/NewSession.swift (issue read, onDisappear)
Fixed in: the change that adds this file

Closing the dialog while it was reading an issue with `gh` could still start an agent on that issue afterwards.
Cause: the issue was read in a Task nothing kept, so closing the dialog did not cancel it, and it started the agent when `gh` answered.
Fix: the form keeps the reading Task, cancels it when the dialog disappears, and the Task checks for cancellation before starting anything.
Lesson: work a dialog starts is cancelled when the dialog closes, and checks for cancellation before it acts.
