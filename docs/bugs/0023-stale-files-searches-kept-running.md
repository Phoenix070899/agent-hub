# Text searches in the Files column kept running after the query changed

Found: 2026-10-22
Where: app/Sources/HubApp/CheckoutFiles.swift (grep, Git.run), app/Sources/HubCore/ProcessStopper.swift, app/Sources/HubApp/FilesColumn.swift
Fixed in: 5cca9ed Stop stale Files searches, match file names off the main thread, and skip ignored files in text search unless asked

Typing a search started a `git grep` per pause, and the older ones ran on to the end, wasting CPU and delaying the current results.
Cause: cancelling the SwiftUI task did not stop the `git grep` process it had launched; the process had no way to be ended from outside.
Fix: a `ProcessStopper` launches git and terminates it when the task is cancelled, and a stop that comes first keeps git from starting at all; a test covers both.
Lesson: every process a cancellable task starts is stopped when the task is cancelled; wire `withTaskCancellationHandler` to the process, not only to the Swift work.
