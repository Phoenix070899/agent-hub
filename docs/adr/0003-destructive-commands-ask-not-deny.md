# Destructive commands are "ask" rules for Workers, not "deny"

Workers run in auto mode, so `rm -rf`, `git reset --hard`, and `curl|sh` would normally be hard-denied. We make them "ask" rules instead: the Orchestrator surfaces the exact command under Needs you, and only after the human explicitly approves that exact command does the Orchestrator accept the prompt, for that single run. A hard deny cannot be lifted even with explicit human approval, which the human wanted to be able to give.
