# Keys for file tabs, and notes on any line of text

Decided: 2026-10-21
Status: accepted

Supersedes: ui-ux/0008's list of shortcuts, which this extends; ui-ux/0019's limit of notes to rendered Markdown, whose keys and bar otherwise stand.
⌃Tab and ⌃⇧Tab move to the next and previous tab of the checkout, the Terminal first; ⌘W closes the shown file tab, and closes a pane only when the Terminal is shown.
A tab can be dragged onto another to take its place.
Open tabs are remembered across relaunches; a file that is gone is dropped.
Text shown as code (any text file, Markdown or HTML as Source) takes a note on a line: + in the gutter, or ↑ and ↓ with Return, as for Markdown blocks; the note quotes that line.
A previewed HTML page keeps its scroll position when the file changes or its tab is shown again, and lists the page's script errors, failed loads, and `console.error` calls under it with a Clear button.
