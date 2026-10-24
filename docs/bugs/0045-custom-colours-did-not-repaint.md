# Custom app colours did not repaint until the mode changed

Found: 2026-10-24
Where: app/Sources/HubApp/Theme.swift (Ledger.apply), app/Sources/HubApp/SettingsView.swift
Fixed in: the change that adds this file

Changing a Custom colour in Settings left the app in the old colours until the human switched Mode between Light and Dark.
Cause: SwiftUI resolves the Ledger's dynamic colours again only when light or dark changes; setting the app's appearance to another one and back in the same turn of the run loop counts as no change.
Fix: colours are edited as a draft and applied with an Apply button; Apply flips the colour scheme the main window's SwiftUI views see and flips it back a tenth of a second later, after a redraw. Flipping the whole app's appearance instead flashed the window white.
Lesson: to make dynamic colours resolve again, change the SwiftUI colour scheme (not the app's appearance) across a redraw, never twice in one run loop turn; and test a recolour within the same mode, as a test that changes the mode passes anyway.
Check it with the window really drawn: a test copy behind other windows or on another Space has `occlusionState` without `.visible` and never redraws, which hides this bug and its fix alike.
