# A Terminal is a plain shell in the repo, not Claude Code

Decided: 2026-10-22
Status: accepted

Supersedes: adr/0006's "Terminal tabs, split panes, and shells are gone", because the human asked for a plain terminal beside the agents.
The + menu, File > New Terminal (⇧⌘N), and Quick Open's New Terminal open a Terminal at once in the selected repo, with no dialog: an agent of kind `terminal` that runs the human's login shell in the repo's checkout.
The + menu no longer offers Claude Code on its own; the Start a session dialog still does.
A Terminal runs no agent: the daemon starts its shell when something first attaches, it always reads as live, it has no stop or resume, and typing into it never names it.
Its shell drops the daemon's inherited `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, and `TERM_SESSION_ID`, so macOS's zshrc does not restore another terminal app's session into it.
A separate shells table, as before adr/0006, was rejected: an agent row already gives a Terminal its place in the ledger, its name, its multiplexer session, and Close.
