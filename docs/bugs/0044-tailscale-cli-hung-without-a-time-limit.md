# Echo Remote waited on the Tailscale CLI with no time limit

Found: 2026-10-24
Where: crates/hub/src/remote.rs (tailscale calls)
Fixed in: the change that adds this file

On the human's Mac, `tailscale status` hung or failed with "Tailscale.CLIError error 3" when run from an agent's shell, and `tailscale serve` waited forever because the tailnet had not allowed Serve yet; Echo's Settings polls the status every few seconds, so each call would have stalled it.
Cause: the daemon ran the CLI with `Command::output()`, which waits as long as the CLI does.
Fix: every Tailscale call gives up after 8 seconds and passes on what the CLI printed (for Serve, the link that allows it); the tailnet name is cached for 30 seconds, and when it changes (the Mac or the tailnet renamed in the Tailscale console) Serve is set up again, as it kept answering only to the old name.
Lesson: give every call to an outside CLI a time limit and surface what it printed; the macOS Tailscale CLI also behaves differently inside tmux or an agent's shell than in Terminal, so check it from the daemon itself.
