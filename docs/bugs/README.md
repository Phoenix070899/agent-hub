# Bugs

Every bug found in Echo, the Hub Daemon, or the `hub` CLI since the project began, each with the lesson that keeps it from coming back.

## Rules

1. One bug per file, named `NNNN-short-slug.md`, numbered in the order found.
2. Before changing an area, read the bug files whose Where line names it, and keep their lessons.
3. Fixing a bug adds its file in the same change, whoever found it: the human, a test, or an end-to-end run.
4. A bug found and fixed while building a change, before it shipped, gets a file too when its lesson would help a later session.
5. A bug file is a record: once committed, add to it only a "Came back:" line when the same bug returns.

## Format

```
# What went wrong, as one sentence

Found: YYYY-MM-DD
Where: the files or area
Fixed in: the commit, or "the change that adds this file"

What the human saw, or what failed.
Cause: why it happened.
Fix: what changed.
Lesson: the rule that keeps it from happening again, stated as what to do.
```
