# Echo: several agents per repo, Normal sessions, and the ledger

The macOS app is renamed Echo, after its mark: one solid square and the fading echoes it sends out, like one Orchestrator and its Workers. The bundle is `Echo.app` (`dev.agenthub.Echo`); the CLI and daemon stay `hub`.
A repo now holds several agents instead of one Orchestrator. The daemon keeps an `agents` table (id, repo, kind, name, model, Claude session id); the old one-per-repo session migrates to the repo's first Orchestrator, so `session.open` and `hub` without an agent still reach it.
An agent is an Orchestrator or a Normal session (plain Claude Code), picked when it starts. Each Worker records the Orchestrator that started it through `HUB_AGENT`, and `hub wait` and the inbox deliver only that Orchestrator's messages.
A Normal session's own permission prompt is a Need like a Worker's, with no Worker; Approve and Deny press the key in its terminal.
The name is optional: a typed name wins, else the daemon names the agent from the first line the human types into it, and Rename changes it later.
The window is a Ledger: cool paper and ink, highlighter yellow only for Needs you, system fonts, the terminal keeping the human's theme. One tab per repo, never more; the ledger groups Needs you, Running, and Done under each agent and never shows other repos. Terminal tabs, split panes, and shells are gone: a terminal multiplexer already does that.
