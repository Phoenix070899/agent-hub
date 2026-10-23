# Rows of a wide Markdown table overlapped each other

Found: 2026-10-19
Where: app/Sources/HubApp/FilePreview.swift (MarkdownTable, TableLayout)
Fixed in: 972db89 Echo: Markdown fills the panel, tables wrap without overlapping, lists count up

In a table with long cells, rows drew on top of each other.
Cause: the table sat in a sideways ScrollView, and wrapped text inside it was measured a line short, so each row was placed too high.
Fix: tables no longer scroll sideways; a custom `TableLayout` sizes columns to their text up to 420 pt, shares what is left when they do not fit, and grows each row to its wrapped height (ui-ux/0020).
Lesson: do not put wrapping text inside a horizontal ScrollView; measure and place it with a Layout that proposes a real width.
