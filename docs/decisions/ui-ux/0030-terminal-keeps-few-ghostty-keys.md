# The terminal keeps only copy, paste, select all, find, and line-editing keys

Decided: 2026-10-21
Status: accepted

Ghostty's own key bindings are cleared (`keybind = clear`), so ⌘K, ⌘N, ⌘D, ⌘W, ⌘1 to ⌘9, and Echo's other shortcuts reach its menus.
The terminal keeps ⌘C, ⌘V, ⌘A, ⌘F (its find field), and ⌘←, ⌘→, ⌘⌫ as Home, End, and delete-line, as Terminal.app has them.
Option is Alt, the cursor does not blink, and programs may copy to the clipboard (OSC 52) but never read it.
The human's own Ghostty config is never loaded, so Echo's terminals look the same whatever Ghostty.app is set to.
