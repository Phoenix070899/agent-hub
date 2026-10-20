# Terminals can show one background image, blurred and dimmed by the theme background

Decided: 2026-10-20
Status: accepted

Settings > Terminal background picks one image file shown behind every terminal: Orchestrators, Normal sessions, and Workers alike.
The theme background covers the image at the Dim setting (0.3 to 0.95, 0.7 by default), and Blur softens it up to 30 pt, so text stays readable.
SwiftTerm's `backgroundOpacity` clears only the default background; text, coloured cells, the cursor, selections, and reverse video stay solid.
Setting the background colour's alpha to 0 directly was rejected: SwiftTerm then drew no text at all.
A look saved before this setting loads without an image; a missing image file falls back to the plain theme background.
