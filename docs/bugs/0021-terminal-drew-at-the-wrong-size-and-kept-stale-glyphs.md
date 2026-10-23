# A new terminal drew at the wrong size, and resizes left stale glyphs

Found: 2026-10-21
Where: app/Sources/HubApp/TerminalPane.swift (show, connect, sizeChanged, settled), app/Sources/HubApp/Terminal/index.html
Fixed in: bbc4f0b Attach terminals at their settled size and repaint after a resize

A new terminal pane showed the agent's screen laid out for another size, then redrew it a moment later; after a resize, old glyphs stayed on screen.
Cause: the pane attached at once with the web view's first-guess size, so the daemon replayed the screen at that size; and the xterm.js WebGL renderer kept stale glyphs in its texture atlas after a resize.
Fix: a pane attaches only after its first layout settles (0.1 s without change), later sizes reach the daemon after 0.2 s, and every resize clears the glyph atlas and repaints all rows (ui-ux/0028).
Lesson: never attach or start a terminal before its pane's size has settled; the first size a view reports is a guess.
