# Echo Remote's page looked blank and its sheets missing in an offscreen render

Found: 2026-10-24
Where: crates/hub/remote/index.html (checked with an offscreen WKWebView)
Fixed in: the change that adds this file

Rendered in an offscreen WKWebView at phone size, the agent page showed an empty screen and the New and Settings sheets never appeared, while the API returned the screen fine.
Cause: the harness, not the page: an offscreen window reports `document.visibilityState` as "hidden", so the page (rightly) stopped reading the screen, and CSS animations never advance there, so sheets that fade in stayed at opacity 0.
Fix: the render harness defines `visibilityState` as "visible" and turns animations off before judging the page.
Lesson: when a page renders blank offscreen, check what the page thinks of its own visibility and animations before blaming the page; check data through the API first to split the two.
