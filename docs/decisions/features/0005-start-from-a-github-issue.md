# A session can start from a GitHub issue, read with gh

Decided: 2026-10-18
Status: accepted

The New session dialog takes an issue number or link; Echo reads it with `gh issue view --json number,title,body,url` in the picked repo, through a login shell.
The issue becomes the new agent's first message (`agent.open` `request`, passed after `--`), for new sessions only; a resumed session never gets it again.
The agent is named "#N title" unless the human typed a name.
Errors show under the field: gh missing, not logged in, or no GitHub remote for a bare number.
Linear is not supported yet, by the human's choice.
