# Highlight with fills, never shadows

Decided: 2026-10-18
Status: accepted

Selection, hover, and focus use the `Ledger.selected`, `Ledger.chosen`, or `Ledger.wash` fills; no element gets a shadow to stand out.
The search field has no shadow.
Only modal dialogs keep their drop shadow, because they float over a dimmed window.
The human asked for this directly.
