# Echo Remote: the Hub Daemon serves a phone web app over Tailscale

The human wants to keep working with their agents from the phone, away from the Mac.
Echo Remote is a web app the Hub Daemon serves itself, so it works whenever the daemon runs, with Echo open or not (ADR 0005).
It shows every repo's ledger, settles Needs (Approve, Deny, Reply), shows an agent's or Worker's screen as text with a message box and keys, starts new agents, and sends Web Push notifications for new Needs.

It listens on 127.0.0.1 only; `tailscale serve` puts it on the human's tailnet over HTTPS, and it is never published to the internet (no Funnel, no LAN bind).
Every API call also needs the pairing token, held by the phone as a cookie; the token is in `$HUB_STATE/remote.json` (mode 0600) and making a new one unpairs every phone.
The server is a thread of the daemon that reads the ledger in-process and sends every action through the daemon's own socket, so the phone can do only what Echo and `hub` can.

Rejected: a native iPhone app, which needs Xcode (only the Command Line Tools are installed); a full terminal emulator on the phone, because Claude Code's screen is too wide to read or type into on a phone, and resizing it would resize the human's terminal on the Mac; Claude Code's own Remote Control alone, which shows one agent at a time without the ledger or Needs.
