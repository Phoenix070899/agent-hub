# Changes and Compare read like a code review

Decided: 2026-10-19
Status: accepted

The Worker header has a segmented control: Terminal (or Final Report once settled), Changes, and Compare for a fan-out try.
Changes shows each file under a sticky header with its +/- counts, then lines with old and new numbers in two 44 pt gutters, added lines on `Ledger.okWash`, removed on `Ledger.failWash`.
A comment sits under its line on a `Ledger.needCard` card, indented to the code column; the review bar at the bottom holds the count and the send buttons.
Compare shows every try as a column card, side by side and top-aligned, with its branch, files changed, Final Report, and Keep this one.
