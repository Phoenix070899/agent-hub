# Text shown as code draws with one AppKit text view, not a SwiftUI row per line

Decided: 2026-10-23
Status: accepted

A previewed file shown as code (any text file, Markdown or HTML as Source) is one non-editable `NSTextView` on TextKit 1 with non-contiguous layout, behind `CodeView.swift`.
The text view draws the gutter (line numbers and the + for a note) and the row backgrounds (keyboard line, search hit, just-changed glow) itself, in `drawBackground`, so no per-line view exists and the gutter scrolls sideways with the code as before.
Notes and the note being written are SwiftUI views hosted inside the text view, in room made under their line with paragraph spacing.
↑ ↓ Return Esc and ⇧Tab reach the preview's own key handling while the text view holds the keyboard, so ui-ux/0019 and 0027 stand.
A code view in a hidden tab sets `isHidden`, as SwiftUI opacity does not hide AppKit views.
Why: a `LazyVStack` of `Text` rows in a two-axis `ScrollView`, each row tracking hover, stuttered on trackpad scrolling in long files; the text view lays out and draws only what is on screen.
Rejected: an `NSRulerView` or a sibling gutter view, because inside SwiftUI either one stopped the code text and the header above it from drawing (see docs/bugs); TextKit 2, because its view-based fragments make drawing under the text unreliable.
