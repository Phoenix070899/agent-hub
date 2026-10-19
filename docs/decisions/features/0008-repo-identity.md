# A repo is always keyed by its main checkout

Decided: 2026-10-19
Status: accepted

The daemon keys every repo by `repo::root`: the main checkout's canonical path (so `/tmp/x` is `/private/tmp/x`), the same from any of its worktrees.
Every method that takes a repo path normalises it this way before storing or comparing it.
