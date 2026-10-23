# Echo opened many login shells at once to start a missing daemon

Found: 2026-10-22
Where: app/Sources/HubApp/AppModel.swift (ensureDaemon)
Fixed in: the change that adds this file

With the daemon down, Echo started a login shell running `hub sessions` from every repo it followed and from the session refresh, all at once, and again on every retry when the start failed.
Cause: `ensureDaemon` had no lock and no memory of a failed start, so each caller tried on its own.
Fix: one start runs at a time under a lock, a caller that waited checks the socket again first, and after a failed start the others get the same error for 30 s instead of opening another shell.
Lesson: starting a shared service is serialized and backs off after a failure; callers that arrive while it starts wait for that start.
