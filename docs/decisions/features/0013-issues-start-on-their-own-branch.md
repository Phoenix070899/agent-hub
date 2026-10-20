# A session started from an issue works on a new branch named after it

Decided: 2026-10-19
Status: accepted

Supersedes: features/0005, whose Issue field ran the agent in the repo's checkout and lived in its own row.
The issue is typed in Create from (the Smart or GitHub tab); Echo reads it with `gh` as before, and it becomes the agent's first message.
The agent works on a new branch `feat/<number>-<title words>` from the picked base, in its own worktree.
The agent is named "#N title" unless the human typed a name; Linear is still not supported.
