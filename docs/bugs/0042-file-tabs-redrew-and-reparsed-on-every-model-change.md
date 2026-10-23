# Every open file tab redrew and re-parsed its Markdown on every app model change

Found: 2026-10-23
Where: app/Sources/HubApp/FilePreview.swift (FilePreviewPanel, MarkdownView, MarkdownBlockView, InlineCache), app/Sources/HubApp/CodeView.swift
Fixed in: the change that adds this file

With file tabs open, Echo spent CPU on every daemon snapshot and cursor move, even on tabs that were not shown.
Cause: the preview views observed the whole AppModel through `@EnvironmentObject`, so any change redrew them, and their bodies parsed inline Markdown with `AttributedString(markdown:)` on each draw.
Fix: heavy views (MarkdownView, CodeView) take plain values and are `.equatable()`, and inline Markdown is parsed once, off the main thread, into a shared NSCache.
Lesson: heavy views take values, not AppModel; never parse or format inside `body`.
