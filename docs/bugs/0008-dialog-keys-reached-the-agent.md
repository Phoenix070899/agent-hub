# Typing and Escape in a dialog reached the agent's terminal behind it

Found: 2026-10-18
Where: app/Sources/HubApp/TerminalPane.swift (focus handling), Echo's dialogs
Fixed in: 8875f62 Echo: ledger redesign, multiplexer panes, Done reports, quick open

With a dialog open, keys the human typed, and Escape meant to close the dialog, went to the agent instead.
Cause: the terminal pane made itself first responder on every update while its pane was focused, taking the keyboard back from the dialog.
Fix: the pane gets a `keyboard` flag that is false while a dialog is open; it then resigns first responder and only takes the keyboard again when allowed.
Lesson: an AppKit view inside SwiftUI must never grab first responder on its own; it takes the keyboard only when the app says it may, and dialogs own it while open.
