# Running git from Echo could hang when git filled its error pipe

Found: 2026-10-22
Where: app/Sources/HubApp/CheckoutFiles.swift (Git.run)
Fixed in: the change that adds this file

A git command that wrote a lot to stderr could hang the read that waited for it, and with it the Files column, search, or diff that ran it.
Cause: `Git.run` read stdout to the end and only then read stderr; once git filled the stderr pipe it blocked writing, so neither side ever finished.
Fix: stderr is read on another thread alongside stdout, and input for stdin is written on its own thread too.
Lesson: drain every pipe of a child process at the same time; never read one to the end before starting the other.
