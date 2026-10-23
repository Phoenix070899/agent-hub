# An HTML or PDF tab's view showed over the tab actually chosen

Found: 2026-10-21
Where: app/Sources/HubApp/FilePreview.swift (FilePreviewPanel, WebPreview, PDFPreview)
Fixed in: df64bf8 Keep the web and PDF views out of the tree while another tab is shown

After opening an HTML or PDF file, choosing another tab or the Terminal still showed the page or PDF.
Cause: tabs are stacked in a ZStack and hidden with SwiftUI `.opacity(0)`, which does not hide an AppKit view such as WKWebView or PDFView.
Fix: the web and PDF views were left out of the tree while their tab was not active (later replaced by hiding them with `isHidden`, ui-ux/0032).
Lesson: SwiftUI opacity never hides an NSViewRepresentable; an AppKit view in a hidden tab hides itself with `isHidden`.
