# A previewed file covers the terminal under a Terminal | file tab strip

Decided: 2026-10-19
Status: accepted

Opening a file shows it in the main panel over the terminal, one file at a time, under a tab strip "Terminal | name ✕"; Esc, the Terminal tab, or ✕ goes back, and the terminal stays attached underneath.
Code shows with line numbers and Highlightr colours (xcode in light, atom-one-dark in dark), up to 300 KB; past that it shows plain, and past 1 MB only the first 1 MB, with a note.
Markdown shows rendered, with a Rendered and Source switch; images and PDFs show as themselves; other binary files show "No preview" with Open and Reveal in Finder.
Lines that change while a file is open glow in `Ledger.justChanged` for two seconds.
The header holds the path, its git mark, Reveal in Finder, Open, and Insert into terminal as the primary button; the path gives way first when the panel is narrow.
