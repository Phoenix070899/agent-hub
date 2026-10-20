# Final Reports stay in Echo for 7 days until dismissed

Decided: 2026-10-18
Status: accepted

The daemon keeps settled Workers in Echo's snapshot for 7 days (`KEEP_REPORTS_SECONDS`) unless the human dismisses them (`worker.dismiss`, `dismissed_at`).
Dismissing only hides a Worker from Echo; the Orchestrator's view and the database keep it.
Read and unread state lives in the app (`readReports` in user defaults), keyed by repo, Worker, and settle time, so a resumed Worker that settles again reads as new.
