# A file tab keeps its web view or PDF view for its whole life

Decided: 2026-10-23
Status: accepted

An HTML or PDF tab makes its `WKWebView` or `PDFView` once and keeps it until the tab closes; while another tab is shown the view sets `isHidden`, because SwiftUI opacity does not hide AppKit views.
Showing the tab again loads nothing and starts no web process; the page reloads only when the file changes, keeping its scroll as ui-ux/0027 says.
Why: removing the view while hidden made every return to an HTML tab start a new web process and load the page again, which showed as a blank flash and a delay.
Rejected: removing the view from the tree while another tab shows, as before.
