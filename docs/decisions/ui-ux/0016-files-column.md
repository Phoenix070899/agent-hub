# A Files column beside the terminal shows the selected checkout

Decided: 2026-10-19
Status: accepted

A 280 pt column on the right of the main panel lists the files of whatever is selected: an agent's or Worker's worktree, else the repo's checkout; its header names the branch.
It is a read-only browser; agents do the editing.
Folders come first, then files, in Finder order; it follows `.gitignore` and never shows `.git`, with an eye button (and a Quick Open command) to show ignored files.
Each changed file carries its git mark in its name's colour: M amber (`Ledger.changed`), A and ? green, D red; a folder with changes inside gets an amber dot.
It reads the checkout again within about half a second of any change, so agents' edits show as they happen.
It starts hidden; whether it shows, and each checkout's open folders, are remembered across selections and relaunches.
