import AppKit
import HubCore
import SwiftUI

/// What the ledger has selected: one of a repo's agents, or one of its Workers.
enum Selection: Hashable {
    case agent(repo: String, id: Int)
    case worker(repo: String, id: String)

    var repo: String {
        switch self {
        case .agent(let repo, _), .worker(let repo, _): return repo
        }
    }
}

/// A short line at the top of an agent's Needs you after the human acts, so they see it landed.
struct Confirmation: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

/// What the New session modal opens with.
struct NewSessionRequest: Equatable {
    var repo: String?
    var kind: Agent.Kind = .orchestrator
}

/// How the window looks. By default it follows the terminal theme, so a dark terminal gets a
/// dark window around it.
enum WindowLook: String, CaseIterable, Identifiable, Codable {
    case matchTerminal, system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .matchTerminal: return "Match the terminal theme"
        case .system: return "Follow macOS"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Showing each agent's and Worker's terminal inside the human's multiplexer, where they can
/// split and add windows beside it.
struct MultiplexerSettings: Codable, Equatable {
    var enabled = true
    /// Run in a login shell with `{session}` (e.g. `echo-demo-a3`), `{dir}` and `{command}` (what
    /// shows the agent in the first pane) filled in, each already shell-quoted.
    var command = MultiplexerSettings.tmux
    /// Picked "Custom command", even while the command still reads like a preset. Optional, so
    /// settings saved before it existed still load.
    var custom: Bool?

    static let tmux = "tmux new-session -A -s {session} -c {dir} {command}"
    /// screen takes a program rather than a shell line, so `sh -c` runs the attach; `-U` for UTF-8.
    static let screen = "cd {dir} && screen -U -xRR -S {session} sh -c {command}"

    /// Which multiplexer this is, for the Settings picker: a known command, none, or the human's own.
    var kind: Multiplexer {
        get {
            guard enabled else { return .none }
            if custom == true { return .custom }
            return Multiplexer.allCases.first { $0.command == command } ?? .custom
        }
        set {
            enabled = newValue != .none
            custom = newValue == .custom ? true : nil
            if let preset = newValue.command { command = preset }
        }
    }
}

enum Multiplexer: String, CaseIterable, Identifiable {
    case tmux, screen, none, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tmux: return "tmux"
        case .screen: return "screen"
        case .none: return "None (plain terminal)"
        case .custom: return "Custom command"
        }
    }

    /// The command it runs; nil for none, and for custom, which keeps whatever was typed.
    var command: String? {
        switch self {
        case .tmux: return MultiplexerSettings.tmux
        case .screen: return MultiplexerSettings.screen
        case .none, .custom: return nil
        }
    }
}

/// The multiplexer shell showing one agent or Worker.
struct MuxShell: Equatable {
    let repo: String
    let shell: Int
    /// The multiplexer's own name for it, like `echo-demo-a3`.
    var session: String?
    let opened: Date
    /// Whether a snapshot has listed it yet.
    var seen = false
}

/// The app's state: every repo the daemon knows, each one's live snapshot, and the selection.
/// Every daemon call runs off the main thread; results come back here.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    /// Models offered when starting an agent; "" keeps the saved one, or `claude`'s default.
    static let models = ["", "claude-opus-5-5", "claude-sonnet-5-5"]

    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var snapshots: [String: Snapshot] = [:]
    @Published var selection: Selection?
    @Published var newSession: NewSessionRequest?
    /// The agent being renamed, if any.
    @Published var renaming: Agent?
    /// The agent waiting on "Close?" to be confirmed, if any.
    @Published var closing: Agent?
    /// A question whose reply field should take the keyboard once the ledger shows it.
    @Published var replyFocus: String?
    /// The window is in full screen, where the traffic lights are hidden.
    @Published var fullScreen = false
    /// Quick open (⌘K) is up.
    @Published var quickOpenShown = false
    /// While a modal is up, terminals hand it the keyboard.
    var modalShown: Bool { newSession != nil || renaming != nil || closing != nil || quickOpenShown || fanOutShown }
    /// Shrinks the ledger to a strip of status marks so the terminal takes almost the whole window.
    @Published var ledgerCollapsed = false

    func toggleLedger() {
        withAnimation(.easeInOut(duration: 0.2)) { ledgerCollapsed.toggle() }
    }
    /// Agent groups folded in the ledger.
    @Published var collapsed: Set<Int> = []
    @Published private(set) var connected = false
    /// True once the daemon could not be reached; the window says so until it is back.
    @Published private(set) var daemonDown = false
    @Published var error: String?
    /// A short note shown under the title bar for a few seconds; see `note(_:)`.
    @Published var notice: String?

    /// The Files column beside the terminal (⇧⌘E); remembered, hidden until first shown.
    @Published var filesShown = UserDefaults.standard.bool(forKey: "filesShown") {
        didSet { UserDefaults.standard.set(filesShown, forKey: "filesShown") }
    }
    /// Files `.gitignore` covers, shown too.
    @Published var showIgnoredFiles = UserDefaults.standard.bool(forKey: "showIgnoredFiles") {
        didSet {
            UserDefaults.standard.set(showIgnoredFiles, forKey: "showIgnoredFiles")
            for files in checkouts.values { files.start(showIgnored: showIgnoredFiles) }
        }
    }
    /// Each checkout's open folders, remembered across selections and relaunches.
    @Published var openFolderMap: [String: Set<String>] =
        (UserDefaults.standard.dictionary(forKey: "openFolders") as? [String: [String]] ?? [:]).mapValues(Set.init) {
        didSet { UserDefaults.standard.set(openFolderMap.mapValues { Array($0) }, forKey: "openFolders") }
    }
    /// The file shown over the terminal; Esc goes back.
    @Published var preview: FileRef? {
        didSet { previewLine = nil }
    }
    /// The line a text search hit opened the preview at, 1-based.
    @Published private(set) var previewLine: Int?
    /// The ledger's and the Files column's widths, as the human dragged them.
    @Published var ledgerWidth = AppModel.width("ledgerWidth", or: 392) {
        didSet { UserDefaults.standard.set(Double(ledgerWidth), forKey: "ledgerWidth") }
    }
    @Published var filesWidth = AppModel.width("filesWidth", or: 280) {
        didSet { UserDefaults.standard.set(Double(filesWidth), forKey: "filesWidth") }
    }

    private static func width(_ key: String, or fallback: CGFloat) -> CGFloat {
        let saved = UserDefaults.standard.double(forKey: key)
        return saved > 0 ? CGFloat(saved) : fallback
    }

    func showPreview(_ file: FileRef, line: Int) {
        preview = file
        previewLine = line
    }
    /// The tree's cursor in each checkout.
    @Published var fileCursor: [String: String] = [:]
    /// The Files tree has the keyboard, so the terminal lets go of it.
    @Published var treeFocused = false
    /// Bumped to move the keyboard to the Files tree.
    @Published var filesFocusRequest = 0
    /// Bumped to hand the keyboard to the previewed file (Tab in the tree).
    @Published var previewFocusRequest = 0
    /// Notes on files, per checkout, until they are sent to the agent working there; in memory
    /// only, as review comments are.
    @Published var fileNotes: [String: [FileNote]] = [:]
    var checkouts: [String: CheckoutFiles] = [:]
    private var noticeHide: DispatchWorkItem?

    /// Says why a key did nothing, for 4 seconds.
    func note(_ text: String) {
        noticeHide?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { notice = text }
        let hide = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.2)) { self?.notice = nil }
        }
        noticeHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: hide)
    }
    /// The latest confirmation per agent.
    @Published private(set) var confirmations: [Int: Confirmation] = [:]

    let client = DaemonClient()
    /// Set by the window, so a notification or the menu bar can bring it back after it closed.
    var openMainWindow: (() -> Void)?

    /// How every terminal looks; Settings edits it.
    @Published var appearance: TerminalAppearance = AppModel.loadAppearance() {
        didSet {
            if let data = try? JSONEncoder().encode(appearance) {
                UserDefaults.standard.set(data, forKey: Self.appearanceKey)
            }
            applyWindowLook()
        }
    }

    @Published var windowLook: WindowLook = AppModel.load(WindowLook.self, key: "windowLook") ?? .matchTerminal {
        didSet {
            Self.save(windowLook, key: "windowLook")
            applyWindowLook()
        }
    }

    /// Terminals drawn by SwiftTerm's Metal renderer instead of Core Graphics. SwiftTerm calls it
    /// experimental, so it is a setting; it falls back to Core Graphics if Metal fails.
    @Published var gpuRendering: Bool = UserDefaults.standard.bool(forKey: "gpuRendering") {
        didSet { UserDefaults.standard.set(gpuRendering, forKey: "gpuRendering") }
    }

    @Published var multiplexer: MultiplexerSettings =
        AppModel.load(MultiplexerSettings.self, key: "multiplexer") ?? MultiplexerSettings()
    {
        didSet {
            Self.save(multiplexer, key: "multiplexer")
            // A new command gets another try everywhere it failed.
            muxFailed.removeAll()
        }
    }

    /// The multiplexer shell showing each agent or Worker, once the daemon has started it.
    @Published private(set) var muxShells: [TerminalTarget: MuxShell] = [:]
    /// Targets whose multiplexer command failed: they show their plain terminal.
    @Published private(set) var muxFailed: Set<TerminalTarget> = []
    private var muxPending: Set<TerminalTarget> = []

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Sets the whole app light or dark; the ledger's colours follow.
    func applyWindowLook() {
        let name: NSAppearance.Name?
        switch windowLook {
        case .matchTerminal: name = appearance.theme.isDark ? .darkAqua : .aqua
        case .system: name = nil
        case .light: name = .aqua
        case .dark: name = .darkAqua
        }
        NSApp?.appearance = name.flatMap { NSAppearance(named: $0) }
    }

    private var trackers: [String: NeedTracker] = [:]
    /// What each repo last showed, so switching back returns to it.
    private var lastSelection: [String: Selection] = [:]
    private static let appearanceKey = "appearance"
    private static let lastRepoKey = "lastRepo"

    private static func loadAppearance() -> TerminalAppearance {
        guard let data = UserDefaults.standard.data(forKey: appearanceKey),
              let saved = try? JSONDecoder().decode(TerminalAppearance.self, from: data) else { return .orca }
        return saved
    }

    /// Each followed repo's events connection generation; bumping it stops the old follower.
    private var following: [String: Int] = [:]
    private var nextGeneration = 0

    var selectedRepo: String? { selection?.repo }
    var selectedSnapshot: Snapshot? { selectedRepo.flatMap { snapshots[$0] } }
    var needsYouCount: Int { snapshots.values.reduce(0) { $0 + $1.needsYouCount } }
    /// Active Workers in every repo.
    var runningCount: Int { snapshots.values.reduce(0) { $0 + $1.workers.filter(\.isActive).count } }
    /// Account-wide: the freshest any repo's snapshot carries.
    var usage: Usage? { snapshots.values.compactMap(\.usage).max { ($0.updatedAt ?? 0) < ($1.updatedAt ?? 0) } }

    func snapshot(_ repo: String) -> Snapshot { snapshots[repo] ?? .empty(repo: repo) }

    func activeCount(_ repo: String) -> Int { snapshot(repo).workers.filter(\.isActive).count }

    /// The repo's agents: from its snapshot once one arrives, else from the session list.
    func agents(_ repo: String) -> [Agent] {
        snapshots[repo]?.agents ?? sessions.first { $0.repo == repo }?.agents ?? []
    }

    /// One tab per repo with a live agent or Workers at work, by name. The order never follows
    /// what is waiting, so a tab and its ⌘-number stay put; the needs badge marks those instead.
    var tabSessions: [SessionInfo] {
        sessions
            .filter { $0.live || activeCount($0.repo) > 0 || $0.repo == selectedRepo }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Repos folded into the "stopped" menu.
    var stoppedSessions: [SessionInfo] {
        let shown = Set(tabSessions.map(\.repo))
        return sessions.filter { !shown.contains($0.repo) }
    }

    func start() {
        applyWindowLook()
        Notifier.requestPermission()
        refreshSessions { sessions in
            let last = UserDefaults.standard.string(forKey: Self.lastRepoKey)
            let pick = sessions.first { $0.repo == last } ?? sessions.first(where: \.live) ?? sessions.first
            if self.selection == nil, let pick { self.selectSession(pick.repo) }
        }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.refreshSessions() }
        }
        readTmuxPrefix()
    }

    // MARK: Splitting the multiplexer

    /// The terminal the main panel shows for the selection, before any multiplexer around it.
    private var selectedTarget: TerminalTarget? {
        switch selection {
        case .agent(_, let id)?: return .agent(id: id)
        case .worker(let repo, let id)?:
            return snapshot(repo).workers.first { $0.id == id }?.number.map { .worker(id: $0) }
        case nil: return nil
        }
    }

    /// ⌘W: closes the tmux pane in focus, and its window if it was the last one there. The pane
    /// showing the agent itself is never closed; tmux would drop the agent's view with it. Away
    /// from tmux, ⌘W closes the window as usual.
    func closePane() {
        guard canSplit, let target = selectedTarget, let session = muxShells[target]?.session else {
            NSApp.keyWindow?.performClose(nil)
            return
        }
        let quoted = "'" + session.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // Exit 3: the focused pane is the agent's own (`hub attach --follow`).
        let script = "case \"$(tmux display -p -t \(quoted): '#{pane_start_command}')\" in *attach*--follow*) exit 3;; esac; tmux kill-pane -t \(quoted):"
        Task.detached {
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
            shell.arguments = ["-lc", script]
            shell.standardOutput = FileHandle.nullDevice
            shell.standardError = FileHandle.nullDevice
            guard (try? shell.run()) != nil else { return }
            shell.waitUntilExit()
            if shell.terminationStatus == 3 {
                await MainActor.run {
                    AppModel.shared.note("⌘W closes panes you added. This one is the agent's own, so it stays; click a pane you added first.")
                }
            }
        }
    }

    /// ⌘D splits by typing tmux keys, so it needs tmux on screen.
    var canSplit: Bool { multiplexer.enabled && multiplexer.command.hasPrefix("tmux") }

    /// The human's tmux prefix as the byte it types; Ctrl-b until tmux says otherwise.
    private var tmuxPrefix: UInt8 = 0x02

    /// ⌘D and ⇧⌘D: splits the shown tmux pane right or down by typing the prefix and `%` or `"`
    /// into it, so the human's own bindings and split options apply.
    func splitPane(down: Bool) {
        guard canSplit else { return }
        let keys = Data([tmuxPrefix, down ? UInt8(ascii: "\"") : UInt8(ascii: "%")])
        NotificationCenter.default.post(name: .muxKeys, object: keys)
    }

    /// Asks tmux for the prefix, through a login shell for the human's PATH, off the main thread.
    private func readTmuxPrefix() {
        guard multiplexer.command.hasPrefix("tmux") else { return }
        Task.detached {
            let shell = Process()
            let out = Pipe()
            shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
            shell.arguments = ["-lc", "tmux start-server \\; show -gv prefix"]
            shell.standardOutput = out
            shell.standardError = FileHandle.nullDevice
            guard (try? shell.run()) != nil else { return }
            shell.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard let byte = tmuxControlByte(text) else { return }
            await MainActor.run { AppModel.shared.tmuxPrefix = byte }
        }
    }

    /// Starts the daemon through a login shell when it is not running, so it, and every agent it
    /// starts, gets the human's PATH (hub, claude) rather than the bare one apps launch with.
    nonisolated static func ensureDaemon(_ client: DaemonClient) throws {
        if (try? HubSocket(path: client.socketPath)) != nil { return }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lic", "hub sessions >/dev/null"]
        shell.standardOutput = FileHandle.nullDevice
        shell.standardError = FileHandle.nullDevice
        try shell.run()
        shell.waitUntilExit()
        _ = try HubSocket(path: client.socketPath)
    }

    /// Reloads the repo list and follows every repo not yet followed. A failure here means the
    /// daemon is out of reach: the window shows that, not an error.
    func refreshSessions(then done: (([SessionInfo]) -> Void)? = nil) {
        background(quiet: true) { client in
            try Self.ensureDaemon(client)
            return try client.sessions()
        } then: { sessions in
            self.sessions = sessions
            self.daemonDown = false
            for session in sessions where self.following[session.repo] == nil {
                self.follow(repo: session.repo)
            }
            // A first session started outside the window (`hub` in a terminal) opens here too.
            if self.selection == nil, let first = sessions.first(where: \.live) ?? sessions.first {
                self.selectSession(first.repo)
            }
            done?(sessions)
        } failed: {
            self.daemonDown = true
        }
    }

    /// Opens the New session modal, on a repo and mode when given.
    func showNewSession(repo: String? = nil, kind: Agent.Kind = .orchestrator) {
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
        newSession = NewSessionRequest(repo: repo, kind: kind)
    }

    /// Reads a GitHub issue with `gh` in `repo`, so a bare number means that repo's issue. Throws
    /// what `gh` printed when it fails: not installed, not logged in, no such issue.
    nonisolated static func fetchIssue(_ reference: String, in repo: String) async throws -> GitHubIssue {
        try await Task.detached {
            let shell = Process()
            let out = Pipe()
            let err = Pipe()
            shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // A login shell for the human's PATH; the reference goes in as an argument, unquoted by nobody.
            shell.arguments = ["-lc", "gh issue view \"$1\" --json number,title,body,url", "zsh", reference]
            shell.currentDirectoryURL = URL(fileURLWithPath: repo)
            shell.standardOutput = out
            shell.standardError = err
            try shell.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let problem = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            shell.waitUntilExit()
            guard shell.terminationStatus == 0 else {
                let said = problem.trimmingCharacters(in: .whitespacesAndNewlines)
                throw IssueError(message: shell.terminationStatus == 127
                    ? "Echo reads issues with the GitHub CLI. Install it with brew install gh, then run gh auth login."
                    : said.contains("no git remotes")
                    ? "This repo has no GitHub remote, so a number alone names no issue. Paste the issue's link instead."
                    : said.isEmpty ? "gh could not read that issue." : said)
            }
            return try JSONDecoder().decode(GitHubIssue.self, from: data)
        }.value
    }

    struct IssueError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Asks for a folder outside the known repos; nil when cancelled.
    func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Choose a git repo."
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }

    /// Starts a new agent in a repo and selects it. An empty name is taken from the first request;
    /// a `request` is that first request, sent as the agent starts.
    func open(repo path: String, kind: Agent.Kind, name: String, model: String, request: String? = nil) {
        background { client in
            try Self.ensureDaemon(client)
            return try client.openAgent(repo: path, kind: kind, name: name, model: model, request: request)
        } then: { opened in
            self.select(.agent(repo: opened.repo, id: opened.agent))
            self.refreshSessions()
        }
    }

    /// Starts a new agent on a branch (`branch`, or `newBranch` from `base`); `done` gets nil once
    /// it runs and is selected, else why it could not start, for the dialog to show.
    func open(repo path: String, kind: Agent.Kind, name: String, model: String, request: String?,
              branch: String?, newBranch: String?, base: String?, then done: @escaping @MainActor (String?) -> Void) {
        let client = client
        Thread.detachNewThread {
            let result = Result {
                try Self.ensureDaemon(client)
                return try client.openAgent(repo: path, kind: kind, name: name, model: model, request: request,
                                            branch: branch, newBranch: newBranch, base: base)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let opened):
                    self.select(.agent(repo: opened.repo, id: opened.agent))
                    self.refreshSessions()
                    done(nil)
                case .failure(let error):
                    done("\(error)")
                }
            }
        }
    }

    func loadBranches(_ repo: String, then done: @escaping @MainActor ((current: String, branches: [RepoBranch])) -> Void) {
        background(quiet: true) { client in try client.branches(repo: repo) } then: { done($0) }
    }

    func select(_ selection: Selection) {
        self.selection = selection
        lastSelection[selection.repo] = selection
        if case .worker(let repo, let id) = selection,
           let worker = snapshot(repo).workers.first(where: { $0.id == id }) {
            setRead(worker, repo: repo, true)
        }
        UserDefaults.standard.set(selection.repo, forKey: Self.lastRepoKey)
        if case .agent(_, let id) = selection { collapsed.remove(id) }
    }

    /// Switches to a repo, back to whatever it last showed, else its first agent.
    func selectSession(_ repo: String) {
        if let last = lastSelection[repo], exists(last) {
            select(last)
        } else if let first = agents(repo).first {
            select(.agent(repo: repo, id: first.id))
        } else {
            selection = nil
        }
    }

    private func exists(_ selection: Selection) -> Bool {
        switch selection {
        case .agent(let repo, let id): return agents(repo).contains { $0.id == id }
        case .worker(let repo, let id): return snapshot(repo).workers.contains { $0.id == id }
        }
    }

    /// The first agent of the current repo (⌘0).
    func showFirstAgent() {
        if let repo = selectedRepo, let first = agents(repo).first { select(.agent(repo: repo, id: first.id)) }
    }

    /// The next (or previous) repo tab, wrapping around.
    func cycleSession(forward: Bool) {
        let tabs = tabSessions.map(\.repo)
        guard !tabs.isEmpty else { return }
        let index = selectedRepo.flatMap { tabs.firstIndex(of: $0) } ?? 0
        selectSession(tabs[(index + (forward ? 1 : tabs.count - 1)) % tabs.count])
    }

    /// Whether an agent's group shows anything under its header: not folded, and an Orchestrator
    /// (Workers, or the hint that there are none), or a session with a Need or a confirmation.
    func showsContent(_ group: AgentGroup) -> Bool {
        guard !collapsed.contains(group.agent.id) else { return false }
        return group.agent.isOrchestrator || !group.needs.isEmpty || confirmations[group.agent.id] != nil
    }

    func toggleCollapsed(_ agent: Int) {
        if collapsed.contains(agent) { collapsed.remove(agent) } else { collapsed.insert(agent) }
    }

    private func follow(repo: String) {
        nextGeneration += 1
        let generation = nextGeneration
        following[repo] = generation
        let client = client
        Thread.detachNewThread { [weak self] in
            while true {
                do {
                    try Self.ensureDaemon(client)
                    let socket = try client.open("events", ["repo": repo])
                    _ = try DaemonClient.result(of: socket.readLine())
                    let current = DispatchQueue.main.sync { () -> Bool in
                        guard let self, self.following[repo] == generation else { return false }
                        self.connected = true
                        self.daemonDown = false
                        return true
                    }
                    guard current else { return socket.shutdown() }
                    while true {
                        let snapshot = try JSONDecoder().decode(Snapshot.self, from: socket.readLine())
                        DispatchQueue.main.async { self?.apply(snapshot, repo: repo, generation: generation) }
                    }
                } catch {
                    let stop = DispatchQueue.main.sync { () -> Bool in
                        guard let self, self.following[repo] == generation else { return true }
                        self.connected = false
                        self.daemonDown = true
                        return false
                    }
                    if stop { return }
                    Thread.sleep(forTimeInterval: 2)
                }
            }
        }
    }

    private func apply(_ snapshot: Snapshot, repo: String, generation: Int) {
        guard following[repo] == generation else { return }
        let before = snapshots[repo]
        snapshots[repo] = snapshot
        var tracker = trackers[repo] ?? NeedTracker()
        for need in tracker.fresh(in: snapshot.needs) {
            Notifier.post(need, repo: repo, agent: need.agent.flatMap { snapshot.agent($0) })
        }
        trackers[repo] = tracker
        forgetEndedMuxes(in: repo, shells: snapshot.shells)
        // A report that arrives while its Worker is on screen has been seen; only as it arrives,
        // so Mark as Unread on the Worker being looked at holds.
        if case .worker(repo, let id)? = selection, let worker = snapshot.workers.first(where: { $0.id == id }),
           worker.settledAt != nil, before?.workers.first(where: { $0.id == id })?.settledAt == nil {
            setRead(worker, repo: repo, true)
        }
        // A Worker that left the ledger, or an agent that was closed, falls back to the repo's first agent.
        if let selection, selection.repo == repo, !exists(selection) {
            if let first = snapshot.agents?.first {
                self.selection = .agent(repo: repo, id: first.id)
            }
        }
    }

    /// Brings the window forward on a Worker, an agent, or the repo.
    func reveal(repo: String?, worker: String?, agent: Int? = nil) {
        if let repo {
            if let worker {
                select(.worker(repo: repo, id: worker))
            } else if let agent {
                select(.agent(repo: repo, id: agent))
            } else {
                selectSession(repo)
            }
        }
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Multiplexer

    /// What a terminal view attaches to: the multiplexer around `target` when that is on and
    /// running, `target` itself when it is off or failed, nil while the multiplexer starts.
    func shownTarget(for target: TerminalTarget) -> TerminalTarget? {
        guard multiplexer.enabled, !muxFailed.contains(target) else { return target }
        return muxShells[target].map { .shell(id: $0.shell) }
    }

    /// Starts the multiplexer around `target` unless it runs, is starting, or failed.
    func ensureMux(_ target: TerminalTarget, repo: String) {
        guard multiplexer.enabled, !muxFailed.contains(target), muxShells[target] == nil,
              !muxPending.contains(target) else { return }
        muxPending.insert(target)
        let command = multiplexer.command
        background { client in
            try client.openMux(target, command: command)
        } then: { opened in
            self.muxPending.remove(target)
            self.muxShells[target] = MuxShell(repo: repo, shell: opened.shell, session: opened.session, opened: Date())
        } failed: {
            self.muxPending.remove(target)
            self.muxFailed.insert(target)
        }
    }

    /// Drops multiplexer shells that exited (the human quit the multiplexer, or it could not
    /// start); the view then starts a new one. One that exits right away marks the command as
    /// failing for that target, so it shows its plain terminal instead of retrying forever.
    private func forgetEndedMuxes(in repo: String, shells: [Int]?) {
        guard let shells else { return }
        let alive = Set(shells)
        for (target, mux) in muxShells where mux.repo == repo {
            let age = Date().timeIntervalSince(mux.opened)
            if alive.contains(mux.shell) {
                if !mux.seen { muxShells[target]?.seen = true }
            } else if mux.seen || age > 3 {
                muxShells[target] = nil
                if age < 5 {
                    muxFailed.insert(target)
                    error = "The multiplexer command exited right away, so \(target.label) shows its own terminal. Check the command in Settings."
                }
            }
        }
    }

    // MARK: Acting on Needs

    func decide(_ need: Need, repo: String, approve: Bool, note: String) {
        if let worker = need.worker {
            decide(worker: worker, repo: repo, agent: need.agent, approve: approve, note: note, what: need.command)
        } else if let agent = need.agent {
            decide(agent: agent, approve: approve, note: note, what: need.command)
        }
    }

    /// Presses Approve or Deny on a Worker's permission prompt; the daemon tells its Orchestrator.
    func decide(worker: String, repo: String, agent: Int?, approve: Bool, note: String, what: String? = nil) {
        guard let number = Int(worker.dropFirst()) else { return }
        background { client in try client.decide(worker: number, approve: approve, note: note) } then: { _ in
            let verb = approve ? "Approved" : "Denied"
            let command = what.map { ": \($0)" } ?? ""
            if let agent { self.confirm("\(verb) \(worker)’s request\(command). Its Orchestrator knows.", for: agent) }
        }
    }

    /// Presses Approve or Deny on a Normal session's own permission prompt.
    func decide(agent: Int, approve: Bool, note: String, what: String? = nil) {
        background { client in try client.decide(agent: agent, approve: approve, note: note) } then: { _ in
            let verb = approve ? "Approved" : "Denied"
            self.confirm("\(verb)\(what.map { " \($0)" } ?? "").", for: agent)
        }
    }

    func reply(_ need: Need, repo: String, text: String) {
        background { client in try client.reply(message: need.message, text: text) } then: { _ in
            if let agent = need.agent, let worker = need.worker {
                self.confirm("Sent your answer to \(worker). Its Orchestrator gets a copy.", for: agent)
            }
        }
    }

    private func confirm(_ text: String, for agent: Int) {
        let confirmation = Confirmation(text: text)
        confirmations[agent] = confirmation
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            if self.confirmations[agent] == confirmation { self.confirmations[agent] = nil }
        }
    }

    // MARK: Agents and Workers

    func startAgent(_ id: Int) {
        background { client in try client.startAgent(id) } then: { _ in self.refreshSessions() }
    }

    func stopAgent(_ id: Int) {
        background { client in try client.stopAgent(id) } then: { _ in }
    }

    /// Takes an agent out of the ledger; its terminal stops. Callers confirm through `closing` first.
    func forgetAgent(_ id: Int) {
        background { client in try client.forgetAgent(id) } then: { _ in self.refreshSessions() }
    }

    /// A new conversation in place of an ended one: same repo, kind and model.
    func startFresh(_ agent: Agent, repo: String) {
        background { client in
            let opened = try client.openAgent(repo: repo, kind: agent.kind, model: agent.model)
            try client.forgetAgent(agent.id)
            return opened
        } then: { opened in
            self.select(.agent(repo: opened.repo, id: opened.agent))
            self.refreshSessions()
        }
    }

    func rename(_ id: Int, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        background { client in try client.renameAgent(id, to: name) } then: { _ in self.refreshSessions() }
    }

    func stopWorker(_ worker: WorkerRow) {
        guard let number = worker.number else { return }
        background { client in try client.closeWorker(number) } then: { _ in }
    }

    // MARK: Changes: a Worker's diff and the human's review of it

    /// What each Worker's panel shows when not its terminal or Final Report, by "repo|w12".
    @Published var workerViews: [String: WorkerView] = [:]
    /// Review comments not sent yet, per Worker ("repo|w12"), kept while the human looks elsewhere.
    @Published var reviews: [String: [ReviewComment]] = [:]

    static func workerKey(_ repo: String, _ worker: WorkerRow) -> String { "\(repo)|\(worker.id)" }

    func workerView(_ repo: String, _ worker: WorkerRow) -> WorkerView {
        workerViews[Self.workerKey(repo, worker)] ?? .main
    }

    func show(_ view: WorkerView, repo: String, worker: WorkerRow) {
        workerViews[Self.workerKey(repo, worker)] = view == .main ? nil : view
    }

    /// The Worker on screen, if a Worker is.
    var selectedWorker: (repo: String, worker: WorkerRow)? {
        guard case .worker(let repo, let id)? = selection,
              let worker = snapshot(repo).workers.first(where: { $0.id == id }) else { return nil }
        return (repo, worker)
    }

    var changesSelected: Bool {
        selectedWorker.map { workerView($0.repo, $0.worker) == .changes } ?? false
    }

    /// ⌥⌘D: the selected Worker's Changes, or back to its terminal or Final Report.
    func toggleChanges() {
        guard let (repo, worker) = selectedWorker else { return }
        show(changesSelected ? .main : .changes, repo: repo, worker: worker)
    }

    // MARK: Fan-outs: one Task, several Workers, one kept

    @Published var fanOutShown = false
    /// What keeping a try did, by fan-out, shown on the Compare view after the others close.
    @Published var kept: [String: String] = [:]

    func showFanOut() {
        guard selectedRepo != nil else { return showNewSession() }
        fanOutShown = true
    }

    /// The selected repo's Orchestrator a fan-out reports to: the one on screen, else the first live one.
    var fanOutOrchestrator: Agent? {
        guard let repo = selectedRepo else { return nil }
        let orchestrators = agents(repo).filter(\.isOrchestrator)
        let shown: Int? = switch selection {
        case .agent(_, let id)?: id
        case .worker(_, let id)?: snapshot(repo).workers.first { $0.id == id }?.agent
        case nil: nil
        }
        return orchestrators.first { $0.id == shown } ?? orchestrators.first(where: \.live) ?? orchestrators.first
    }

    func loadProfiles(then done: @escaping @MainActor ([WorkerProfile]) -> Void) {
        background(quiet: true) { client in try client.profiles() } then: { done($0) }
    }

    /// Starts the fan-out; `done` gets nil on success, else why it failed. The first try is shown.
    func fanOut(repo: String, agent: Int?, profile: String, title: String, spec: String, branch: String,
                count: Int, then done: @escaping @MainActor (String?) -> Void) {
        let client = client
        Thread.detachNewThread {
            let result = Result {
                try client.fanOut(repo: repo, agent: agent, profile: profile, title: title, spec: spec,
                                  branch: branch, count: count)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let started):
                    if let first = started.workers.first { self.select(.worker(repo: repo, id: first)) }
                    done(started.failed.isEmpty ? nil : "Some tries did not start: " + started.failed.joined(separator: "; "))
                case .failure(let error):
                    done("\(error)")
                }
            }
        }
    }

    /// Keeps `worker`: merges its branch and closes the other tries.
    func keep(_ worker: WorkerRow, repo: String) {
        guard let number = worker.number, let fanout = worker.fanout else { return }
        background { client in try client.pickWorker(number) } then: { picked in
            self.select(.worker(repo: repo, id: worker.id))
            self.show(.compare, repo: repo, worker: worker)
            self.kept[fanout] = "Kept \(worker.id): merged \(picked.branch) into \(picked.into). The other tries are closed; their branches stay."
        }
    }

    func loadDiff(_ worker: WorkerRow, then done: @escaping @MainActor (Result<(diff: String, truncated: Bool), Error>) -> Void) {
        guard let number = worker.number else { return }
        let client = client
        Thread.detachNewThread {
            let result = Result { try client.workerDiff(number) }
            DispatchQueue.main.async { done(result) }
        }
    }

    /// Sends the Worker's review; on success the comments are cleared.
    func sendReview(repo: String, worker: WorkerRow, toWorker: Bool, then done: @escaping @MainActor () -> Void) {
        let key = Self.workerKey(repo, worker)
        guard let number = worker.number, let comments = reviews[key], !comments.isEmpty else { return }
        let body = reviewBody(comments)
        background { client in
            try client.reviewWorker(number, toWorker: toWorker, body: body)
        } then: { _ in
            self.reviews[key] = nil
            done()
        }
    }

    // MARK: Done: read, unread, dismissed

    /// Final Reports the human has opened, as "repo|w12|settledAt": one that settles again after
    /// a resume reads as new.
    @Published private var readReports: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "readReports") ?? [])

    private func reportKey(_ worker: WorkerRow, repo: String) -> String? {
        worker.settledAt.map { "\(repo)|\(worker.id)|\($0)" }
    }

    /// A settled Worker whose report the human has not opened yet.
    func isUnread(_ worker: WorkerRow, repo: String) -> Bool {
        reportKey(worker, repo: repo).map { !readReports.contains($0) } ?? false
    }

    func setRead(_ worker: WorkerRow, repo: String, _ read: Bool) {
        guard let key = reportKey(worker, repo: repo), readReports.contains(key) != read else { return }
        if read { readReports.insert(key) } else { readReports.remove(key) }
        // Reports leave Done within a week, so the newest few hundred keys are plenty.
        let kept = readReports.sorted { ($0.split(separator: "|").last ?? "") > ($1.split(separator: "|").last ?? "") }.prefix(500)
        UserDefaults.standard.set(Array(kept), forKey: "readReports")
    }

    /// Takes settled Workers off the Done list.
    func dismiss(_ workers: [WorkerRow]) {
        let numbers = workers.compactMap(\.number)
        guard !numbers.isEmpty else { return }
        background { client in
            for number in numbers { try client.dismissWorker(number) }
        } then: { _ in }
    }

    func refreshUsage() {
        background { client in try client.call("usage.refresh") } then: { _ in }
    }

    /// Runs `work` off the main thread, then hands its result to `then`. A failure shows as the
    /// window's error, or, when `quiet`, only reaches `failed`.
    private func background<T>(
        quiet: Bool = false,
        _ work: @escaping @Sendable (DaemonClient) throws -> T,
        then: @escaping @MainActor (T) -> Void,
        failed: (@MainActor () -> Void)? = nil
    ) {
        let client = client
        Thread.detachNewThread {
            let result = Result { try work(client) }
            DispatchQueue.main.async {
                switch result {
                case .success(let value):
                    if !quiet { self.error = nil }
                    then(value)
                case .failure(let error):
                    if !quiet { self.error = "\(error)" }
                    failed?()
                }
            }
        }
    }
}

extension Notification.Name {
    /// Keys for the multiplexer on screen; the terminal showing one types them into it.
    static let muxKeys = Notification.Name("EchoMuxKeys")
    /// Text for the terminal on screen, whatever it shows: into the focused tmux pane, or the agent.
    static let typeIntoTerminal = Notification.Name("EchoTypeIntoTerminal")
}

/// A file in a checkout, by the checkout's folder and its path inside it.
struct FileRef: Hashable {
    let root: String
    let path: String

    var url: URL { URL(fileURLWithPath: root).appendingPathComponent(path) }
    var name: String { (path as NSString).lastPathComponent }
}

extension AppModel {
    // MARK: Files: the selected checkout's files, and the one being previewed

    /// The folder the selection works in: an agent's or Worker's worktree, else the repo's checkout.
    var selectedCheckout: String? {
        switch selection {
        case .agent(let repo, let id)?:
            return agents(repo).first { $0.id == id }?.cwd ?? repo
        case .worker(let repo, let id)?:
            return snapshot(repo).workers.first { $0.id == id }?.cwd ?? repo
        case nil:
            return nil
        }
    }

    /// Whether the terminal on screen is live, so a path can be typed into it.
    var terminalTypeable: Bool {
        switch selection {
        case .agent(let repo, let id)?: return agents(repo).first { $0.id == id }?.live ?? false
        case .worker(let repo, let id)?:
            return snapshot(repo).workers.first { $0.id == id }.map { $0.isActive && $0.live } ?? false
        case nil: return false
        }
    }

    /// What the terminal on screen is called: the agent's name, or the Worker's id.
    var terminalName: String? {
        switch selection {
        case .agent(let repo, let id)?: return agents(repo).first { $0.id == id }?.displayName
        case .worker(_, let id)?: return id
        case nil: return nil
        }
    }

    /// Pastes the checkout's notes into the terminal on screen and presses Return, then clears
    /// them. A paste, so the agent reads the notes as one message, not a line at a time.
    func sendNotes(root: String) {
        guard terminalTypeable, selectedCheckout == root, let notes = fileNotes[root], !notes.isEmpty else { return }
        let text = "\u{1b}[200~" + notesBody(notes) + "\u{1b}[201~"
        let count = notes.count
        let name = terminalName ?? "the agent"
        fileNotes[root] = nil
        preview = nil
        // After the terminal takes the screen back; Return on its own, as the daemon sends a review.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .typeIntoTerminal, object: Data(text.utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NotificationCenter.default.post(name: .typeIntoTerminal, object: Data("\r".utf8))
                self.note("Sent \(count) note\(count == 1 ? "" : "s") to \(name).")
            }
        }
    }

    /// The checkout's files, read and watched from the first time they are asked for.
    func checkoutFiles(_ root: String) -> CheckoutFiles {
        if let files = checkouts[root] {
            files.start(showIgnored: showIgnoredFiles)
            return files
        }
        let files = CheckoutFiles(root: root)
        checkouts[root] = files
        files.start(showIgnored: showIgnoredFiles)
        return files
    }

    func openFolders(_ root: String) -> Set<String> { openFolderMap[root] ?? [] }

    func setFolder(_ folder: String, open: Bool, in root: String) {
        var folders = openFolderMap[root] ?? []
        if open { folders.insert(folder) } else { folders.remove(folder) }
        openFolderMap[root] = folders
    }

    /// The file the Files menu commands act on: the one previewed, else the tree's cursor.
    var fileInFocus: FileRef? {
        if let preview, preview.root == selectedCheckout { return preview }
        guard let root = selectedCheckout, let path = fileCursor[root] else { return nil }
        return FileRef(root: root, path: path)
    }

    /// Types `@path ` into the terminal on screen and shows it, so the human sees it land.
    func insertMention(_ file: FileRef) {
        guard terminalTypeable else { return }
        preview = nil
        let text = mentionText(file.path)
        // After the terminal takes the screen back.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .typeIntoTerminal, object: Data(text.utf8))
        }
    }

    func openInEditor(_ file: FileRef) { NSWorkspace.shared.open(file.url) }

    func revealInFinder(_ file: FileRef) { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }

    func copyPath(_ file: FileRef) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.url.path, forType: .string)
        note("Copied \(file.url.path)")
    }

    /// ⇧⌘E: shows the Files column and gives it the keyboard; shown but elsewhere, gives it the
    /// keyboard; already in it, hides it and the terminal takes the keyboard back.
    func toggleFiles() {
        if filesShown && !treeFocused {
            filesFocusRequest += 1
            return
        }
        if !filesShown { filesFocusRequest += 1 }
        withAnimation(.easeOut(duration: 0.15)) { filesShown.toggle() }
    }
}

/// What a Worker's panel shows.
enum WorkerView: Hashable {
    /// Its terminal while it works, else its Final Report.
    case main
    case changes
    /// Every try of its fan-out side by side.
    case compare
}
