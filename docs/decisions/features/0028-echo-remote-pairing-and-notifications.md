# Echo Remote pairs a phone by link, and pushes new Needs and Final Reports

Decided: 2026-10-24
Status: accepted

`hub remote on` (or the switch in Echo's Settings) turns Echo Remote on: the daemon serves it on 127.0.0.1:7480 and runs `tailscale serve --bg --https=443` to it, so the phone opens `https://<mac>.<tailnet>.ts.net` with no port to remember; the human asked for the shorter address, so Echo Remote takes the tailnet's default HTTPS port for this Mac.
A phone pairs by opening the pairing link (Echo shows it as a QR code); the page trades the token for an HttpOnly, SameSite=Strict cookie that lasts a year.
`hub remote pair` (New Pairing Link in Echo) makes a new token and forgets every phone's notifications, so every phone pairs again.
The phone may call only what Echo's buttons call: decide, reply (always as the human's), terminal.send, terminal.key, agent.open, agent.close, worker.dismiss, branches.list; a POST from another site, or one that is not JSON, is refused.
Text sent from the phone goes to the agent's or Worker's running terminal only, never a shell it would start; several lines go as one bracketed paste.
Each new Need, and each Worker's Final Report, is pushed to every phone that turned notifications on, with Echo's own wording ("w3 bash wants to run"); what was waiting when the daemon started is not pushed.
Pushes are Web Push (RFC 8291 payload, RFC 8292 VAPID), posted with `curl`; a push service that answers 404 or 410 drops that phone.
Under test (`HUB_TEST_AGENT`), Tailscale is never touched.
Why: the human wants to settle Needs and keep agents moving away from the Mac (ADR 0008).
