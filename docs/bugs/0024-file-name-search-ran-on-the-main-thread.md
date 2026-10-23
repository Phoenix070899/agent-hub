# File name search matched every path on the main thread

Found: 2026-10-22
Where: app/Sources/HubApp/FilesColumn.swift (search results), app/Sources/HubCore/Files.swift (searchFiles, FileTree.lowercasedFiles)
Fixed in: 5cca9ed Stop stale Files searches, match file names off the main thread, and skip ignored files in text search unless asked

In a big checkout, typing in the Files search lagged on every keystroke.
Cause: the view called `searchFiles` inside its body on the main thread, lowercasing every path of tens of thousands for each keystroke.
Fix: names match in a detached task keyed on the query and tree generation, and the tree keeps its paths lowercased once.
Lesson: never do work that grows with the checkout inside a view body or on the main thread; run it off the main thread, keyed so a newer query cancels it.
