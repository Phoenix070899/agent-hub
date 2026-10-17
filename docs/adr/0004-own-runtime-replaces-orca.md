# Agent Hub owns its runtime; Orca is removed

We replace Orca with our own runtime: a Rust Hub Daemon that owns Worker terminals (PTYs it keeps alive and screen-parses), worktrees, Tasks, and the message bus, driven by a `hub` CLI and, later, a native Swift app.
Orca's terminal layer forced workarounds we could not fix from outside: it types nudges into the human's prompt, needs the trust prompt answered by keystrokes, and exposes Worker state only through its private database.
The Orchestrator hears from Workers only through a background `hub wait`; the daemon never types into its terminal.
Blockers are caught twice: the daemon reads each Worker's screen, and the Worker's Notification hook reports to the daemon.
Cutover is one change after an end-to-end test, with no period of supporting both runtimes.
The daemon starts on the first `hub` command and keeps running; a login agent comes with the Swift app.
It persists Tasks and each Worker's Claude session id, so after a daemon crash a lost Worker is resumed with `claude --resume`, not restarted.
Until the Swift app exists, a Worker's terminal is opened on demand in Ghostty with `hub attach`, and the Orchestrator stays in the human's own terminal.
