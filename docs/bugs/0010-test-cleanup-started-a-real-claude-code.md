# Stopping the test daemon first let a test pane start a real Claude Code

Found: 2026-10-19
Where: Echo end-to-end test cleanup (CLAUDE.md, "Testing Echo end to end"), `hub attach --follow`
Fixed in: 0205793 Echo: Cmd-W works after Echo reconnects; say why the agent's own pane stays

After an end-to-end run, a real Claude Code started under the test state folder.
Cause: the cleanup stopped the test daemon while test tmux panes still ran `hub attach --follow`, which started the daemon again, now without `HUB_TEST_AGENT`, so it launched the real `claude`.
Fix: CLAUDE.md now orders the cleanup: kill the tmux sessions whose start command contains the test state folder, then `hub shutdown --force` with the test env, then remove the test folders.
Lesson: tear a test down from the outside in: stop whatever can restart the daemon before stopping the daemon.
