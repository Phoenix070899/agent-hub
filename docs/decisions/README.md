# Decisions

Every decision about Echo and the Hub Daemon that a later change must respect.

- `ui-ux/`: how Echo looks, reads, and responds to the human.
- `features/`: what Echo and the daemon do, and the rules behind each feature.
- `../adr/`: the architecture decisions that came first (runtime, daemon, app, multiplexer); they bind the same way.

## Rules

1. One decision per file; a file that needs "and also" is two files.
2. Read the decisions that touch your change before you build it, and follow them.
3. Never edit a decision file once it is committed, not even to fix it.
4. To overrule a decision, add a new file in the same folder with the next number, and start its body with `Supersedes: ui-ux/0003` (or the path it replaces) and why.
5. A decision is in force unless a later file names it in a `Supersedes:` line; check with `grep -rn "Supersedes" docs/decisions docs/adr`.
6. Add a decision file when a change makes a choice a later session could undo by accident: a look, a rule, a default, a trade-off.

## Format

File name: `NNNN-short-slug.md`, numbered per folder.

```
# The decision, as one sentence

Decided: YYYY-MM-DD
Status: accepted

Supersedes: features/0002 (only when it does), and why.
What was decided, one sentence per line.
Why, and what was rejected.
```
