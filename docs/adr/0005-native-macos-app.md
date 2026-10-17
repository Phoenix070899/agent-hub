# A native macOS app views the Hub Daemon; it owns nothing

We build Hub.app now, before the planned week of daemon-only use, because the human asked for it.
It is a SwiftUI app (SwiftPM in `app/`, built unsigned for this Mac, no Xcode needed) with one window per Hub Session and a menu bar icon.
The Hub Daemon owns every terminal, the Orchestrator's included, so quitting the app stops nothing; the app is a client of the same socket as the `hub` CLI.
Terminals render with SwiftTerm behind one interface, so libghostty can replace it later for speed and fidelity.
v1 is the Worker sidebar, embedded terminals, a Needs you inbox with Approve and Deny, macOS notifications, and the menu bar count; worktree merges, history, multi-repo switching, launch at login, and a global hotkey wait for real use.
The daemon starts or reuses one Orchestrator per repo and keeps its Claude session id, so `hub` and the app both attach to the same one.
Approve and Deny press the key on the Worker directly, and the daemon tells the Orchestrator what the human decided, so nothing is ever typed into the Orchestrator.
The app follows one `events` stream from the daemon instead of polling; closing its last window keeps it in the menu bar.
