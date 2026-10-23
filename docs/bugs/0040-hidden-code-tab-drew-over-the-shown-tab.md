# A code view in a hidden file tab drew over the shown tab and took its mouse and keys

Found: 2026-10-23
Where: app/Sources/HubApp/CodeView.swift (CodeView update, `isHidden`)
Fixed in: the change that adds this file

With several file tabs open, a code tab that was not chosen could draw on top of the chosen tab and take its clicks, scrolling, and keys.
Cause: SwiftUI `.opacity(0)` does not hide AppKit views, the same root cause as 0019.
Fix: CodeView sets `isHidden` on its scroll view whenever its tab is not active.
Lesson: every NSViewRepresentable inside a tab hidden by opacity hides itself with `isHidden`.
