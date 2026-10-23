# A stopped agent shows a shell in its checkout instead of an ended screen

Decided: 2026-10-22
Status: accepted

When an Orchestrator or a Claude Code session is not running, its panel shows a login shell in the agent's checkout, started by the daemon when something attaches to the agent.
The panel header keeps the way back: Start Orchestrator, or Start fresh and Resume for a Claude Code session; Close stays in the ledger's menu.
Starting the agent again ends its shell, and `hub attach --follow` moves to the agent; while the agent is stopped it follows the shell, so the multiplexer pane never goes blank.
Why: the human wanted a terminal to keep working in after exiting Claude Code, not a page of buttons.
Keeping Claude Code inside a shell in one terminal was rejected: the daemon could no longer tell the agent ended, and Resume would have to type a long command line into it.
