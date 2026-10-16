# Orca is the Worker runtime

We use Orca's orchestration runs (terminals, worktrees, workers, mailbox, ask/reply, decision gates) as the runtime for Workers instead of building our own on tmux or WezTerm. Orca already does every runtime job the design needs, so Agent Hub only adds Agent Profiles, the Worker Contract, and the Orchestrator's rules. The Orchestrator is Claude Code using the Orca `orchestration` skill, not omp's kakashi, whose helpers run in-process with no terminal of their own.
