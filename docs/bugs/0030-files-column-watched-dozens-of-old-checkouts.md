# The Files column kept watching dozens of closed Workers' worktrees

Found: 2026-10-22
Where: app/Sources/HubApp/AppModel.swift (checkoutFiles), app/Sources/HubApp/CheckoutFiles.swift (stop)
Fixed in: the change that adds this file

After a day of fan-outs, every agent write anywhere ran git in many checkouts no one was looking at.
Cause: each checkout's files were watched from the first time they were asked for and never let go, and each watched checkout runs three or four git commands on every write inside it.
Fix: asking for a checkout's files stops every other checkout's watcher and lets it go; coming back reads it again (features/0025).
Lesson: a watcher lives only while its view is on screen; stop it when the view goes, and read again on return.
