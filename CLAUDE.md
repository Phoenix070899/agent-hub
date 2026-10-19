# Agent Hub

Echo (the macOS app in `app/`) and the Hub Daemon with its `hub` CLI (Rust, `crates/hub/`).
Domain words and their meanings are in `CONTEXT.md`; use them in code, copy, and commits.

## Decisions come first

Before changing anything, read the decisions that touch it:

- `docs/decisions/ui-ux/`: how Echo looks and behaves.
- `docs/decisions/features/`: what Echo and the daemon do, and their rules.
- `docs/adr/`: the architecture decisions; they bind the same way.

Every change obeys the decisions in force.
To overrule one, add a new decision file that supersedes it; never edit a committed decision file.
When a change makes a new choice a later session could undo by accident, record it as a new decision file in the same change.
`docs/decisions/README.md` has the rules and the format; one decision per file.

## Build and test

- Rust: `~/.cargo/bin/cargo test` (cargo is not on the default PATH); `cargo fmt --check` must pass.
- Swift: `make -C app test` (plain `swift test` misses the Swift Testing macro plugin); `make -C app app` builds `app/build/Echo.app`.
- Only the Command Line Tools are installed: SwiftUI's `@State` macro does not build, so local view state is an `ObservableObject` held in `@StateObject` (`Flag`, `Draft`, and the like); `@FocusState` works.

## Testing Echo end to end

- Never test against the human's daemon, repos, or tmux sessions: use `HUB_STATE=/tmp/hubui` (short, for the socket path limit), `HUB_TEST_AGENT=crates/hub/tests/fake-agent.sh`, and a throwaway repo whose folder name differs from any real one.
- Run a copy of the app with its own bundle id (`dev.agenthub.Echo.test`), so it shares no defaults or saved windows with the human's Echo.
- Do not steal focus while the human uses the Mac: capture the window with `screencapture -l <window id>` and post keys to the app's process instead of clicking.
- Afterwards stop the test daemon (`hub shutdown --force` with the test env), kill only tmux sessions whose start command contains the test state folder, and remove the test folders.
