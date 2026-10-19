# Terminals draw with SwiftTerm; the GPU renderer is opt-in

Decided: 2026-10-18
Status: accepted

SwiftTerm draws every terminal, behind `TerminalPane.swift` only, so libghostty can replace it (ADR 0005).
Settings has "Draw terminals with the GPU (Metal)", off by default while SwiftTerm marks it experimental.
