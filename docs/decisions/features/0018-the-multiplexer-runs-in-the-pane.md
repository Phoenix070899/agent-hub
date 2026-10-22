# The multiplexer runs in Echo's terminal pane, not in a daemon shell

Decided: 2026-10-21
Status: accepted

Supersedes: adr/0007's clause that `mux.open` starts one daemon-owned shell per agent or Worker, because with libghostty (ui-ux/0029) the pane has a terminal of its own, so that shell and the relay into it were two needless hops on every key.
The daemon's `mux.command` fills in the multiplexer command from Settings (`{session}`, `{dir}`, `{command}`) and returns the line; it starts nothing.
The pane runs `hub mux` with that line in `HUB_MUX`, which replaces itself with a login shell running it, so the multiplexer client is the pane's own process.
A key now goes Ghostty, tmux, `hub attach --follow`, the agent; before it also passed `hub attach --echo` and the daemon's shell.
The agent's terminal stays owned by the daemon, in the multiplexer's first pane, so the rest of adr/0007 stands.
What Echo types into a multiplexer pane (⌘D's keys, dropped paths, notes) goes to the pane's own terminal byte for byte, and the multiplexer hands it to its focused pane.
A multiplexer that exits within 5 s marks its command as failing for that target, which then shows its own terminal; one the human quits later is started again.
Rejected: running the agent itself in a tmux pane, because Needs you, Approve and Deny, naming, and notifications need the daemon to own its terminal.
