# Backlog

Ideas for the Hub App after v1, newest first.
Each needs its own short grilling before it is built.

## Floating Hub button

A small always-on-top floating button, visible over every app on screen.
Clicking it opens a panel that shows:
- every Worker of the Hub Session with its state (needs you, running, done, failed),
- the Orchestrator's latest Summary when it writes one,
- the current Needs you item as a choice to pick or an action to confirm (Approve, Deny, a reply, a selection), so the human can act without switching to the Hub App window.

Open questions: one button per Hub Session or one for all, where it sits and whether it can be dragged, and whether it hides when nothing is running.

## Deferred from Hub App v1 (ADR 0005)

- Worktree panel: each branch's `git diff --stat`, with a Merge button that asks first.
- Report history: past Tasks and their Final Reports, searchable.
- Multiple repos: one window per Hub Session, switched with Cmd-1 to Cmd-9.
- Launch at login: a login agent keeps the Hub Daemon running.
- Global hotkey to bring the Hub App forward.
