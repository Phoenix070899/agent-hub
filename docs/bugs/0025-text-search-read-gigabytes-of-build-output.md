# Text search took 15 s because it read the ignored build folders

Found: 2026-10-22
Where: app/Sources/HubApp/CheckoutFiles.swift (grep), app/Sources/HubApp/FilesColumn.swift, app/Sources/HubApp/QuickOpen.swift
Fixed in: 5cca9ed Stop stale Files searches, match file names off the main thread, and skip ignored files in text search unless asked

With ignored files shown in the tree, a text search took about 15 s instead of 0.13 s.
Cause: text search followed the tree's eye button, so `git grep --no-exclude-standard` read the build folders, about 5.6 GB in this repo.
Fix: text search reads tracked and untracked files only, unless the human ticks "Ignored files" or uses its Quick Open command (features/0019).
Lesson: showing ignored files is cheap and searching them is not; keep costly scopes behind their own explicit switch.
