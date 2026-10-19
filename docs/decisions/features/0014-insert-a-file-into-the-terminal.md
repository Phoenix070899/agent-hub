# Insert into terminal types the file's @path into the terminal on screen

Decided: 2026-10-19
Status: accepted

It types `@` and the path relative to the checkout, shell-escaped like a dropped file, with a space after, into the terminal on screen; with tmux, the focused pane gets it.
Typed into a Worker it is an Intervention, as any typing there is.
When the agent or Worker is not live, it is disabled, with a tooltip saying there is no terminal to type into; browsing and preview still work.
A file can also be dragged from the tree into the terminal or another app; the right-click menu offers Preview, Insert into Terminal, Open, Reveal in Finder and Copy Path.
The daemon now sends each Worker's folder (`cwd`) in Echo's snapshot; an older daemon leaves it out, and Echo then shows the repo's checkout for a Worker.
