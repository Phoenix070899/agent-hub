# Terminals draw with libghostty, each pane running `hub attach --echo`

Decided: 2026-10-21
Status: accepted

Supersedes: ui-ux/0024, because the human chose libghostty over xterm.js for speed; and ui-ux/0028's repaint clause, which was xterm.js's GPU atlas workaround.
libghostty draws every terminal on the GPU (Metal), behind `TerminalPane.swift` only.
Each pane is a Ghostty surface whose command is `hub attach --echo <target>`, because libghostty only draws terminals it runs a process in; the daemon still owns every terminal.
`--echo` lets Ctrl-] reach the agent, and keeps the screen with a dim "[terminal ended]" line when the terminal ends.
A pane still starts only after its first layout settles (about 0.1 s), and `hub attach` passes a new size on once it has held for 0.2 s, so ui-ux/0028's size rules stand.
With the multiplexer on, the pane runs the multiplexer itself instead (features/0018).
What Echo types itself (dropped paths, notes) goes to the daemon's `terminal.write`, byte for byte, not through the surface.
With a background image, the default background is clear (`background-opacity = 0`) and cells with their own colour stay solid, so ui-ux/0022 stands and the GPU stays on.
libghostty is built from a pinned Ghostty commit by `app/Ghostty/build.sh` with Zig, and `ghostty.patch` compiles the Metal shaders at run time, so no Xcode is needed.
Rejected: feeding the daemon's bytes to libghostty directly, because its embedding API has no such call; and libghostty-vt with a renderer of our own, as far more work.
