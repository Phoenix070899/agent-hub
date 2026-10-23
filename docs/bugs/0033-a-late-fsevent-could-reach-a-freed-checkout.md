# A late file event could reach a CheckoutFiles that was already freed

Found: 2026-10-22
Where: app/Sources/HubApp/CheckoutFiles.swift (watch, stop)
Fixed in: the change that adds this file

Once the Files column started letting go of checkouts it no longer showed (0030), an event already queued by the file watcher could call into a freed object and crash Echo.
Cause: the FSEventStream context passed `self` unretained with no retain or release callbacks, so the stream did not keep the object alive until it was stopped.
Fix: the stream's context retains the CheckoutFiles and releases it when the stream is invalidated, and `stop()` cancels a pending read.
Lesson: a C callback context that points at a Swift object retains it for as long as the callback can fire; never pass `passUnretained` to a stream that outlives a scope.
