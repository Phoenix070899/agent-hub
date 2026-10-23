# The Files column has Files, Changes, and Commits tabs

Decided: 2026-10-24
Status: accepted

Under the column's header (the branch, then the eye on Files only, then close), underlined tabs Files, Changes, and Commits switch what the column shows; the tab is remembered across relaunches.
Files is the tree and search of ui-ux/0016; Changes lists every file git status marks, by path, name in its mark's colour with its folder and mark; Commits lists the branch's commits.
Commits are the ones on the branch that its base lacks (the remote's default branch, else main, else master), up to 300; on the base itself, or detached, the latest 50 on HEAD; a line above the list says which.
A commit row shows its subject, short hash, author, and age; opening it lists the files it touched, and a file previews as it is now in the checkout.
Changes and Commits show their counts in the tabs; commits are read only while the Commits tab shows, so an agent's writes run no extra git elsewhere.
Each list takes the tree's keys: ↑ ↓ move, Space opens a commit or previews a file, Return types a file's `@path`, Esc closes the preview, and Tab hands the keyboard to it.
Rejected for now: a commit's or a change's diff in the main panel, which the human chose to leave for later.
