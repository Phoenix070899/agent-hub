# The events stream sends a snapshot only when it changed

Decided: 2026-10-22
Status: accepted

The daemon checks each repo every 5 seconds and after every change, but writes a snapshot line only when it differs from the last one it sent.
Echo's Worker rows carry `quietSince` (Unix seconds), not `quietSeconds`, so an idle repo's snapshot stays the same; Echo counts the quiet time up itself.
Echo also drops a snapshot equal to the one it holds, since every publish on the app model redraws the whole window.
`hub status` still prints `quietSeconds`, for the Orchestrator.
Why: `quietSeconds` changed every tick, so each repo redrew the whole window at least every 5 seconds while nothing happened.
A per-repo observable model was rejected for now: with unchanged snapshots gone, redraws follow real changes only.
