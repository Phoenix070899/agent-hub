# Window's Appearance can be Custom, set up like the terminal theme

Decided: 2026-10-24
Status: accepted

Appearance in Settings' Window tab gains Custom, next to Match the terminal theme, Follow macOS, Light, and Dark.
Custom works like the terminal theme: a Preset (Echo Light, Echo Dark, and one made from each terminal preset), a Light or Dark mode, and five colours (Background, Surface, Text, Accent, Highlighter); changing any of them makes the preset read Custom.
Match the Terminal Theme fills Custom from the terminal theme in use.
Every other Ledger token is mixed from the five in `Theme.swift`, so views still take colours only from `Ledger`; done, failed, changed, and their washes keep the chosen mode's values, so their meaning stays readable.
It adds to ui-ux/0005: views still take colours only from the Ledger tokens.
Mode sets the app's appearance, so system controls follow it; the terminal keeps its own theme.
A change applies at once: the app passes through the mode's high-contrast twin for a moment, as Ledger colours resolve again only when the appearance changes.
Why: the human wanted to choose Echo's own colours, the way they already choose the terminal's.
