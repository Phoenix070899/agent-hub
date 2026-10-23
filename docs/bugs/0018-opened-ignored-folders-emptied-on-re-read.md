# An ignored folder opened in the Files column lost its contents on the next re-read

Found: 2026-10-20
Where: app/Sources/HubApp/CheckoutFiles.swift (fillIfNeeded, fill, read)
Fixed in: 74415f1 Focus the terminal on selection, show the Final Report as Markdown, drop the mod's Dashboard band

After opening an ignored folder such as `target/`, any change in the checkout collapsed it back to an empty folder.
Cause: git lists an ignored folder as one entry, so its contents were filled in by hand on first open, and every re-read replaced the tree and dropped them.
Fix: the column remembers the ignored folders it filled and fills them again, parents first, after each re-read.
Lesson: state added on top of a tree that is rebuilt must be re-applied after every rebuild; keep it apart from the rebuilt data.
