# Worker rows keep their height and show their branch

Decided: 2026-10-19
Status: accepted

A Worker row in the ledger never grows or shrinks on hover or selection; its second line is drawn whenever it has something to say, or not at all.
The second line shows the Worker's worktree branch in monospace when it has one, then its latest status, or Failed or Blocked when it settled badly.
Selection, hover, and status changes animate (about 0.15 s), and rows starting, settling, or leaving fade while the rows below slide, so nothing jumps.
