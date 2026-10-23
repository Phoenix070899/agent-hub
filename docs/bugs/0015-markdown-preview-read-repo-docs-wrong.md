# The Markdown preview drew most repo docs wrong

Found: 2026-10-19
Where: app/Sources/HubCore/Files.swift (parseMarkdown), app/Sources/HubApp/FilePreview.swift
Fixed in: 2ae21ee Echo: render Markdown front matter, tables, nested and task lists

Front matter showed as a rule and a run-on paragraph, tables as joined text, and nested lists flat.
Cause: the first parser knew only headings, paragraphs, flat lists, quotes, code blocks, and rules, so anything else fell into a paragraph.
Fix: the parser reads front matter, tables with alignment, nested and task lists with continuation lines, multi-line quotes, setext headings, hard breaks, `~~~` fences, and drops HTML comments, with tests.
Lesson: test a renderer against the repo's own documents (docs/decisions, CONTEXT.md), not only against a hand-made sample.
