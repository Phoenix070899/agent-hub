# The human leaves notes on a rendered Markdown file and sends them to the agent as one message

Decided: 2026-10-19
Status: accepted

A note goes on one rendered block (heading, paragraph, list item, quote, table, code), not on selected text, because SwiftUI cannot read a text selection; each block knows the source lines it came from.
Notes are kept per checkout in memory until sent or discarded, across the files of that checkout; they do not survive a quit.
Sending pastes them into the terminal on screen as one bracketed paste, then presses Return: each note as `path:line` or `path:first-last`, the quoted lines (a block over 8 lines keeps its first 4 and last 3), then the note.
Typed into a Worker it is an Intervention, as any typing there is; when the terminal is not live, Send is disabled with a tooltip.
Like Orca's review notes, rejected: copying the notes to the clipboard for the human to paste, which adds a step for the common case.
