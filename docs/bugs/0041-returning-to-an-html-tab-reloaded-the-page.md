# Returning to an HTML tab started a new web process and reloaded the page

Found: 2026-10-23
Where: app/Sources/HubApp/FilePreview.swift (PreviewContent, WebPreview, WebPage, PDFPreview)
Fixed in: the change that adds this file

Every time the human came back to an HTML tab, the page flashed blank and loaded again after a delay.
Cause: the WKWebView was removed from the tree while another tab showed (the fix for 0019), so each return built a new web view with a new web process.
Fix: PreviewContent keeps one WKWebView or PDFView per tab for the tab's whole life and hides it with `isHidden` while another tab shows; the page reloads only when the file changes (ui-ux/0032).
Lesson: keep expensive AppKit views alive per tab and hide them; never rebuild a web view just to hide it.
