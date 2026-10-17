import AppKit
import HubCore
import SwiftUI

/// What the sidebar has selected: a session's Orchestrator, or one of its Workers.
enum Selection: Hashable {
    case orchestrator(repo: String)
    case worker(repo: String, id: String)

    var repo: String {
        switch self {
        case .orchestrator(let repo), .worker(let repo, _): return repo
        }
    }
}

/// The app's state: every Hub Session the daemon knows, each one's live snapshot, and the
/// selection. Every daemon call runs off the main thread; results come back here.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var snapshots: [String: Snapshot] = [:]
    @Published var selection: Selection?
    /// Sessions whose Worker list is folded in the sidebar.
    @Published var collapsed: Set<String> = []
    @Published private(set) var connected = false
    @Published var error: String?

    let client = DaemonClient()
    /// Set by the window, so a notification or the menu bar can bring it back after it closed.
    var openMainWindow: (() -> Void)?

    private var trackers: [String: NeedTracker] = [:]
    /// Each followed session's events connection generation; bumping it stops the old follower.
    private var following: [String: Int] = [:]
    private var sockets: [String: HubSocket] = [:]
    private var nextGeneration = 0
    private static let lastRepoKey = "lastRepo"

    var selectedRepo: String? { selection?.repo }
    var selectedSnapshot: Snapshot? { selectedRepo.flatMap { snapshots[$0] } }
    var needsYouCount: Int { snapshots.values.reduce(0) { $0 + $1.needsYouCount } }
    /// Account-wide: the freshest any session's snapshot carries.
    var usage: Usage? { snapshots.values.compactMap(\.usage).max { ($0.updatedAt ?? 0) < ($1.updatedAt ?? 0) } }

    func start() {
        Notifier.requestPermission()
        refreshSessions { sessions in
            let last = UserDefaults.standard.string(forKey: Self.lastRepoKey)
            let pick = sessions.first { $0.repo == last } ?? sessions.first(where: \.live) ?? sessions.first
            if self.selection == nil, let pick { self.selection = .orchestrator(repo: pick.repo) }
        }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.refreshSessions() }
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

    /// Reloads the session list and follows every session not yet followed.
    func refreshSessions(then done: (([SessionInfo]) -> Void)? = nil) {
        background { client in
            try Self.ensureDaemon(client)
            return try client.sessions()
        } then: { sessions in
            self.sessions = sessions
            for session in sessions where self.following[session.repo] == nil {
                self.follow(repo: session.repo)
            }
            done?(sessions)
        }
    }

    func chooseSession() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open Session"
        panel.message = "Choose a git repo for the Hub Session."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(repo: url.path)
    }

    /// Starts (or finds) the repo's Orchestrator and selects it.
    func open(repo path: String) {
        background { client in
            try Self.ensureDaemon(client)
            let result = try client.call("session.open", ["repo": path]) as? [String: Any]
            return result?["repo"] as? String ?? path
        } then: { repo in
            self.select(.orchestrator(repo: repo))
            self.collapsed.remove(repo)
            self.refreshSessions()
        }
    }

    func select(_ selection: Selection) {
        self.selection = selection
        UserDefaults.standard.set(selection.repo, forKey: Self.lastRepoKey)
    }

    func toggleCollapsed(_ repo: String) {
        if collapsed.contains(repo) { collapsed.remove(repo) } else { collapsed.insert(repo) }
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
                        self.sockets[repo] = socket
                        self.connected = true
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
        snapshots[repo] = snapshot
        var tracker = trackers[repo] ?? NeedTracker()
        for need in tracker.fresh(in: snapshot.needs) {
            Notifier.post(need, repo: repo)
        }
        trackers[repo] = tracker
        if case .worker(let selected, let id)? = selection, selected == repo,
           !snapshot.workers.contains(where: { $0.id == id }) {
            selection = .orchestrator(repo: repo)
        }
    }

    /// Brings the window forward on a session's Worker, or its Orchestrator.
    func reveal(repo: String?, worker: String?) {
        if let repo {
            collapsed.remove(repo)
            select(worker.map { .worker(repo: repo, id: $0) } ?? .orchestrator(repo: repo))
        }
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func decide(_ need: Need, approve: Bool, note: String) {
        guard let worker = Int(need.worker.dropFirst()) else { return }
        background { client in try client.decide(worker: worker, approve: approve, note: note) } then: { _ in }
    }

    func reply(_ need: Need, text: String) {
        background { client in try client.reply(message: need.message, text: text) } then: { _ in }
    }

    func refreshUsage() {
        background { client in try client.call("usage.refresh") } then: { _ in }
    }

    func stopOrchestrator(repo: String) {
        background { client in try client.call("session.close", ["repo": repo]) } then: { _ in }
    }

    /// Runs `work` off the main thread; shows its error, or hands its result to `then`.
    private func background<T>(
        _ work: @escaping @Sendable (DaemonClient) throws -> T,
        then: @escaping @MainActor (T) -> Void
    ) {
        let client = client
        Thread.detachNewThread {
            let result = Result { try work(client) }
            DispatchQueue.main.async {
                switch result {
                case .success(let value):
                    self.error = nil
                    then(value)
                case .failure(let error):
                    self.error = "\(error)"
                }
            }
        }
    }
}
