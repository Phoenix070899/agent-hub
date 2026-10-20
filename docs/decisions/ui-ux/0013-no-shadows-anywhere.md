# Echo draws no shadows anywhere

Decided: 2026-10-19
Status: accepted

Supersedes: ui-ux/0003, which kept a drop shadow on modal dialogs; the human asked for no shadow in Echo at all.
No view in Echo uses `.shadow`.
Modal cards stand apart from the dimmed window with a 1 pt `Ledger.rule` hairline around their rounded corners instead.
Highlighting still uses fills only.
Shadows macOS draws itself (the window, menus, system dialogs) are left as the system draws them.
