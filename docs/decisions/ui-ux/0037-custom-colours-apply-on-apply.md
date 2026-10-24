# Custom app colours apply only on Apply

Decided: 2026-10-24
Status: accepted
Supersedes: ui-ux/0036, only its line that a change applies at once

In Settings' Window tab, Preset, Mode, the five colours, and Match the Terminal Theme change a draft; Apply, at the bottom, puts it on the app, and Revert drops it.
A line beside the buttons says whether the draft is applied.
On Apply, only the colour scheme the main window's views see flips for a tenth of a second and back (`LookRefresh`), as SwiftUI resolves Ledger colours again only when it changes; the app's appearance stays, so nothing flashes, and picking colours never repaints the app.
Rejected: flipping the whole app's appearance, which flashed the window white.
Why: applying each change at once did not repaint until the mode changed, and the human chose an Apply button over a repaint on every pick.
