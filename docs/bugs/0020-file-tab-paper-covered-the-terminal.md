# Choosing the Terminal tab showed blank paper instead of the terminal

Found: 2026-10-21
Where: app/Sources/HubApp/ContentView.swift (MainPanel), app/Sources/HubApp/FilePreview.swift (FilePreviewPanel)
Fixed in: 1a5fd89 Hide a file tab's paper with the tab, so the terminal shows when it is chosen

With a file tab open, picking the Terminal tab showed an empty paper-coloured panel.
Cause: ContentView added `.background(Ledger.paper)` to each FilePreviewPanel outside the panel's own `.opacity(active ? 1 : 0)`, so the hidden tab's background still covered the terminal.
Fix: the paper background moved inside the panel, before its opacity, so it hides with the tab.
Lesson: apply hide modifiers last, after every background and overlay, so nothing of a hidden view stays on screen.
