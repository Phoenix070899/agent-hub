# Previewed files keep their tabs beside the Terminal tab

Decided: 2026-10-21
Status: accepted

Supersedes the one-file-at-a-time and close-on-return parts of 0017-file-preview.md; the rest of 0017 stands.

Every file opened for preview gets its own tab after "Terminal", in the order opened, and keeps it until its ✕ is clicked; opening a file that has a tab selects that tab.
The strip shows the tabs of the selected checkout, and appears as soon as one file is open, over the terminal as well.
The Terminal tab and Esc show the terminal without closing any file; each file keeps its scroll position and Rendered or Source choice while another tab is shown.
Closing the shown tab selects the next tab, else the one before, else the Terminal.
