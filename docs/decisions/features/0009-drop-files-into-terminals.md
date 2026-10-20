# Files dropped on a terminal type their paths

Decided: 2026-10-18
Status: accepted

Dropped files and images type their paths at the cursor, shell-escaped and space-separated, as Terminal.app does, so Claude Code can read or attach them.
An image with no file behind it (from a browser) is saved as a PNG under the temporary folder `EchoDrops` first.
