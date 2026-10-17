import AppKit
import HubCore
import SwiftUI

/// What the sidebar has selected.
enum Selection: Hashable {
    case orchestrator
    case worker(String)
}

/// The app's state: which Hub Session it shows, that session's live snapshot, and the selection.
/// Every daemon call runs off the main thread; results come back here.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var repo: String?
    @Published private(set) var snapshot: Snapshot?
    @Published var selection: Selection? = .orchestrator
    @Published private(set) var connected = false
    @Published var error: String?

    let client = DaemonClient()
    /// Set by the window, so a notification or the menu bar can bring it back after it closed.
    var openMainWindow: (() -> Void)?

    private var tracker = NeedTracker()
    private var events: HubSocket?
    private var generation = 0
    private static let lastRepoKey = "lastRepo"

    var repoName: String { repo.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No session" }

    func start() {
        Notifier.requestPermission()
        background { client in
            try Self.ensureDaemon(client)
            return try client.sessions()
        } then: { sessions in
            self.sessions = sessions
            let last = UserDefaults.standard.string(forKey: Self.lastRepoKey)
            if let repo = last ?? sessions.first(where: \.live)?.repo ?? sessions.first?.repo {
                self.open(repo: repo)
            }
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

    func chooseSession() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open Session"
        panel.message = "Choose a git repo for the Hub Session."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(repo: url.path)
    }

    /// Starts (or finds) the repo's Orchestrator and follows its session.
    func open(repo path: String) {
        background { client in
            try Self.ensureDaemon(client)
            let result = try client.call("session.open", ["repo": path]) as? [String: Any]
            return (result?["repo"] as? String ?? path, try client.sessions())
        } then: { (repo: String, sessions: [SessionInfo]) in
            self.sessions = sessions
            self.repo = repo
            self.snapshot = nil
            self.selection = .orchestrator
            self.tracker = NeedTracker()
            UserDefaults.standard.set(repo, forKey: Self.lastRepoKey)
            self.follow(repo: repo)
        }
    }

    private func follow(repo: String) {
        events?.shutdown()
        generation += 1
        let generation = generation
        let client = client
        Thread.detachNewThread { [weak self] in
            while true {
                do {
                    try Self.ensureDaemon(client)
                    let socket = try client.open("events", ["repo": repo])
                    _ = try DaemonClient.result(of: socket.readLine())
                    let stillCurrent = DispatchQueue.main.sync { () -> Bool in
                        guard let self, self.generation == generation else { return false }
                        self.events = socket
                        self.connected = true
                        return true
                    }
                    guard stillCurrent else { return socket.shutdown() }
                    while true {
                        let snapshot = try JSONDecoder().decode(Snapshot.self, from: socket.readLine())
                        DispatchQueue.main.async { self?.apply(snapshot, generation: generation) }
                    }
                } catch {
                    let stop = DispatchQueue.main.sync { () -> Bool in
                        guard let self, self.generation == generation else { return true }
                        self.connected = false
                        return false
                    }
                    if stop { return }
                    Thread.sleep(forTimeInterval: 2)
                }
            }
        }
    }

    private func apply(_ snapshot: Snapshot, generation: Int) {
        guard generation == self.generation else { return }
        self.snapshot = snapshot
        for need in tracker.fresh(in: snapshot.needs) {
            Notifier.post(need)
        }
        if case .worker(let id)? = selection, !snapshot.workers.contains(where: { $0.id == id }) {
            selection = .orchestrator
        }
    }

    /// Brings the window forward on a Worker (or the Orchestrator).
    func reveal(worker: String?) {
        if let worker { selection = .worker(worker) }
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

    func stopOrchestrator() {
        guard let repo else { return }
        background { client in try client.call("session.close", ["repo": repo]) } then: { _ in }
    }

    func restartOrchestrator() {
        guard let repo else { return }
        open(repo: repo)
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
