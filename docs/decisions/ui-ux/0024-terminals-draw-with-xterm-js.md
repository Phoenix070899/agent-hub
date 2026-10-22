# Terminals draw with xterm.js in a web view, for now

Decided: 2026-10-20
Status: accepted

Supersedes: ui-ux/0011, and the SwiftTerm clause of adr/0005 ("Terminals render with SwiftTerm behind one interface"), because the human chose xterm.js for now.
xterm.js, in a `WKWebView`, draws every terminal, behind `TerminalPane.swift` and `app/Sources/HubApp/Terminal/` only, so libghostty can still replace it later (ADR 0005).
The Hub Daemon still owns every terminal; the web view only draws bytes from the attach socket and sends keys back.
The "Draw terminals with the GPU (Metal)" setting is gone: it was SwiftTerm's, and xterm.js has no equivalent switch.
Decision 0022 stands in everything but its SwiftTerm detail: the default background is still cleared when an image is set, and text, coloured cells, and selections stay solid.
xterm.js and its fit and web-links add-ons are vendored in `Terminal/`, so the app needs no network or Node at build time.
Rejected: libghostty now, because its embedding API is young and has to be built from Zig.
