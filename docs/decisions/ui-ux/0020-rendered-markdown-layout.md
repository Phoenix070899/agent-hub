# Rendered Markdown fills the panel, and tables size their columns to their text

Decided: 2026-10-19
Status: accepted

Rendered Markdown runs the full width of the panel, inside 40 pt side margins; a fixed reading measure left wide windows half empty.
A table's columns are as wide as their widest cell, up to 420 pt; when that is more than the page, narrow columns keep their width, the others share the rest evenly, and rows grow to fit the wrapped text.
Tables do not scroll sideways: wrapped text inside a sideways scroll view measured rows a line short, and the rows overlapped.
An ordered list counts up from its first number, so items written "1." each read 1, 2, 3.
