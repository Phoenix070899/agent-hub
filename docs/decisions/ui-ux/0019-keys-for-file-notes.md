# Keys for notes on a previewed file

Decided: 2026-10-19
Status: accepted

Supersedes: ui-ux/0018's list of keys in the tree, which this extends with Tab; its other rules still hold.
Tab in the tree hands the keyboard to the previewed file; ⇧Tab in the preview hands it back to the tree.
In rendered Markdown, ↑ and ↓ move a block cursor, Return opens a note on it, Return saves the note, ⌥Return starts a new line, and Esc cancels the note before it closes the preview.
⇧⌘Return sends the notes while a file is previewed; Changes' ⇧⌘Return works only while no file covers it.
With the mouse, + in the left margin of a hovered block starts a note; the block's text stays selectable, so a click on it does not.
The bar under the preview shows how to leave a note, or the notes waiting with Discard and "Send to <agent>".
