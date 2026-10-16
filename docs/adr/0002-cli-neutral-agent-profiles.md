# Agent Profiles are CLI-neutral files

Workers can run on different agent CLIs (claude, codex, omp, opencode), so an Agent Profile is one file in `profiles/` that names its CLI, and the Orchestrator turns it into that CLI's launch command. We rejected keeping each profile in its CLI's native agent format, because "model + tools + role + skills + context" would then mean something slightly different per CLI and live in several places.
