# A terminal attaches only once its pane's size has settled

Decided: 2026-10-21
Status: accepted

A new terminal pane waits for its first layout to settle (about 0.1 s without a size change) before it attaches to the daemon, so the screen the daemon replays is drawn at the pane's real size, never at the web view's first guess.
Later size changes still reach the daemon after 0.2 s without change.
After every resize the page clears the GPU glyph atlas and repaints all rows, so no stale glyphs stay.
