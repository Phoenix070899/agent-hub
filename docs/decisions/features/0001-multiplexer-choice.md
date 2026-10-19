# The human picks the multiplexer; Echo drives tmux splits itself

Decided: 2026-10-18
Status: accepted

Settings offers tmux (default), screen, none, or a custom command with `{session}`, `{dir}`, and `{command}`.
Sessions are named `echo-<repo>-a<id>` or `-w<id>`, and the agent runs in the first pane through `hub attach --follow`.
⌘D and ⇧⌘D split by typing the human's own tmux prefix (read from tmux) and `%` or `"`, so their bindings apply; they work for tmux only.
⌘W closes the focused tmux pane but refuses (beeps) on the agent's own pane; with no tmux view it closes the window.
