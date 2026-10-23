# Code previews showed only line numbers, and the header and tab strip went blank

Found: 2026-10-23
Where: app/Sources/HubApp/CodeView.swift (CodeTextView, CodeCoordinator)
Fixed in: the change that adds this file

A file shown as code drew its line numbers and nothing else: no code text, and the file header and tab strip above it went blank too.
Cause: the gutter was an NSRulerView on the NSScrollView inside a SwiftUI NSViewRepresentable; inside SwiftUI, the ruler (and also a plain sibling gutter NSView that drew by querying the text view's layout manager) stopped the text view and the SwiftUI header above it from drawing.
Fix: the text view draws the gutter and the row backgrounds itself, in `drawBackground`, so no extra view sits beside it (ui-ux/0031).
Lesson: inside a SwiftUI representable, draw an AppKit view's extras (gutters, row backgrounds) inside that view's own drawing.
Check the result from what the layers hold (`window.contentView.superview.layer.render(in:)` in a test build, or `screencapture -l <window id>` where screen recording is allowed); `NSView.cacheDisplay` redraws the views itself and showed the text fine, which hid this bug.
