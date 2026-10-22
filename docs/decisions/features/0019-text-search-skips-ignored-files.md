# Text search in the Files column skips ignored files unless the human asks for them

Decided: 2026-10-22
Status: accepted

Text search reads tracked and untracked files only, whether or not ignored files are shown in the tree.
An "Ignored files" checkbox beside the Text results, and a Quick Open command, make it read ignored files too; the choice is remembered.
File name search still matches whatever the tree lists, ignored files included when they are shown.
Why: with ignored files shown, `git grep --no-exclude-standard` read the build folders (about 5.6 GB in this repo) and took 15 s instead of 0.13 s.
Tying text search to the eye button was rejected: showing ignored files in the tree is cheap, searching them is not.
