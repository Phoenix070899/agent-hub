# Agents show inside the human's multiplexer; the window follows the terminal theme

Echo keeps no panes of its own (ADR 0006), but the human wants shells beside an agent without leaving the window. So the terminal panel runs their multiplexer, and the agent sits in its first pane.
`mux.open` starts one daemon-owned shell per agent or Worker running a command from Settings, `tmux new-session -A -s {session} -c {dir} {command}` by default. `{session}` is a stable name like `echo-lanh-a3`, so splits and windows the human adds come back when they return. `{command}` is `hub attach --follow a3`, which stays in the pane and reattaches whenever the agent restarts, until the agent is closed.
The agent's terminal stays owned by the daemon, so Needs you, Approve and Deny, naming, and notifications work unchanged; the multiplexer is only a view. A command that exits right away falls back to the plain terminal for that target and says so, rather than retrying forever.
The window now follows the terminal theme by default (a dark theme gives a dark window), with Follow macOS, Light, and Dark as alternatives. Before, the theme only coloured terminals, which read as the setting not working.
