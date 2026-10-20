# Closing an agent asks first; stopping an Orchestrator keeps its Workers

Decided: 2026-10-18
Status: accepted

Close takes an agent out of the ledger and is confirmed in a dialog that names what keeps running.
Stop (or End session) only ends the terminal; the agent stays, ready to resume.
Stopping or closing an Orchestrator never stops its Workers.
