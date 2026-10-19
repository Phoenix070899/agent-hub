# Start a session has a Create from section, after Orca's

Decided: 2026-10-19
Status: accepted

Below the repos, "Create from (optional)" holds four tabs (Smart, GitHub, Branch, Name), one search field, and at the right a base-branch picker that new branches start from.
Smart reads what is typed: an issue number or link, else a branch the repo has, else a name for a new branch; so every choice is reachable from the keyboard without the tabs.
Branch lists up to 5 matching branches, each saying whether an agent already works there.
One line under the field says what will happen ("Works on a new branch feat/x from main, in its own worktree."), in the failure colour when it needs a second look, like a branch another agent is on.
The field is focused when the dialog opens; Name and Model share one row below it.
The ledger and the panel header show each agent's branch: "Orchestrator, feat/login".
