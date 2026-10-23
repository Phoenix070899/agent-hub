# Echo spun at full CPU when a daemon line arrived in two reads

Found: 2026-10-19
Where: app/Sources/HubCore/HubSocket.swift (readLine, readChunk)
Fixed in: 8c25a33 Echo: read a daemon line that arrives in two reads instead of spinning on it (again on the other branch as d95f0f8)

Echo sat at full CPU and the ledger stopped updating, typically on a large snapshot.
Cause: `readLine` took its next chunk from `readChunk`, which first hands back the partial line already buffered, so a line split across socket reads appended the buffer to itself forever and never read the socket.
Fix: `readLine` reads new bytes straight from the socket (`readSocket`); a test writes a 40 KiB line in two parts over a socketpair.
Lesson: a buffered reader takes new bytes only from the source; test every line protocol with a line split across reads.
