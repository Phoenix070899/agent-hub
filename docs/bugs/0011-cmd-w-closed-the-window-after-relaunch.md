# After Echo relaunched, Cmd-W closed the window instead of the tmux pane

Found: 2026-10-19
Where: crates/hub/src/daemon.rs (mux.open), app/Sources/HubApp/AppModel.swift
Fixed in: 0205793 Echo: Cmd-W works after Echo reconnects; say why the agent's own pane stays

Cmd-W worked on tmux panes until Echo was relaunched; then it fell back to closing the window.
Cause: `mux.open` returned only the shell id when it handed back a multiplexer shell it already had, without the tmux session name, so a reconnected Echo did not know which session to send the close to.
Fix: `mux.open` names the session on every answer, the reused shell included; a daemon test opens the same shell twice and checks the session.
Lesson: an answer for a reconnecting client carries everything a fresh one gets; test the second call, not only the first.
