# The Files column re-read the checkout twice a second forever, holding Echo at 45% CPU

Found: 2026-10-22
Where: app/Sources/HubApp/CheckoutFiles.swift (Git.run, watch, changed)
Fixed in: the change that adds this file

Echo used about 45% CPU while idle on a 30,000-file repo, and builds caused the same churn.
Cause: the column's own `git status` took `.git/index.lock` to refresh the index, the file watcher saw that write and read the checkout again, which ran `git status` again; build output in ignored folders also woke the watcher.
Fix: git runs with `GIT_OPTIONAL_LOCKS=0`, and while ignored files are hidden a change only inside folders git ignores (learned with `git check-ignore`) reads nothing (features/0020).
Lesson: a watcher must not be woken by its own reads; run git read-only with `GIT_OPTIONAL_LOCKS=0`, and filter events to paths the view can show.
