# Every repo redrew Echo's whole window every 5 seconds while nothing happened

Found: 2026-10-22
Where: crates/hub/src/daemon.rs (events stream, Worker rows), app/Sources/HubCore/Models.swift (WorkerRow.quietSince), app/Sources/HubApp/AppModel.swift (apply, refreshSessions)
Fixed in: the change that adds this file

An idle Echo kept redrawing its window, costing CPU with nothing on screen changing.
Cause: Worker rows carried `quietSeconds`, which changed every tick, so each 5-second snapshot differed; every snapshot published on AppModel redraws the whole window.
Fix: rows carry `quietSince` and Echo counts up itself; the daemon sends a snapshot only when it differs from the last, and Echo drops an equal snapshot and skips publishing unchanged values (features/0024).
Lesson: never put a value that changes with the clock into shared state; send a timestamp and compute the elapsed time where it is drawn, and publish only real changes.
