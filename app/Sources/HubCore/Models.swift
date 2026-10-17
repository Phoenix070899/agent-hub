import Foundation

/// One Hub Session as the daemon's `events` stream draws it.
public struct Snapshot: Decodable, Equatable, Sendable {
    public struct Orchestrator: Decodable, Equatable, Sendable {
        public let live: Bool
    }

    public let repo: String
    public let orchestrator: Orchestrator
    public let workers: [WorkerRow]
    public let needs: [Need]

    public init(repo: String, orchestrator: Orchestrator, workers: [WorkerRow], needs: [Need]) {
        self.repo = repo
        self.orchestrator = orchestrator
        self.workers = workers
        self.needs = needs
    }

    public static func empty(repo: String) -> Snapshot {
        Snapshot(repo: repo, orchestrator: Orchestrator(live: false), workers: [], needs: [])
    }

    public var needsYouCount: Int { needs.count }
}

/// A Worker's Dashboard state.
public enum WorkerState: String, Decodable, Sendable {
    case needsYou = "needs you"
    case running
    case failed
    case done
}

public struct WorkerRow: Decodable, Equatable, Identifiable, Sendable {
    /// `w12`.
    public let id: String
    public let profile: String
    public let title: String
    public let state: WorkerState
    /// The Worker's lifecycle state: starting, running, done, blocked, exited, lost.
    public let phase: String
    public let quietSeconds: Int
    public let place: String
    public let branch: String?
    public let live: Bool
    public let blocker: String?
    public let finalReport: String?

    /// The daemon's numeric id, as `decide` and `attach` take it.
    public var number: Int? { Int(id.dropFirst()) }
}

/// Something only the human can settle: a Worker's question or a waiting prompt.
public struct Need: Decodable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Decodable, Sendable {
        case question
        case permissionPrompt = "permission_prompt"
        case idlePrompt = "idle_prompt"
        case other

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .other
        }
    }

    public let kind: Kind
    /// The daemon message id behind it: the question to answer, or the blocker report.
    public let message: Int
    public let worker: String
    public let profile: String
    public let title: String
    public let body: String
    /// For a permission prompt: its own lines, ending in "Do you want to ...".
    public let prompt: String?
    public let at: Int

    public var id: String { "\(kind.rawValue)-\(message)" }
}

public struct SessionInfo: Decodable, Equatable, Identifiable, Sendable {
    public let repo: String
    public let live: Bool

    public var id: String { repo }
    public var name: String { URL(fileURLWithPath: repo).lastPathComponent }
}

/// What a terminal view shows.
public enum TerminalTarget: Hashable, Sendable {
    case orchestrator(repo: String)
    case worker(id: Int)

    /// The daemon's way of naming it in `attach` and `terminal.resize`.
    public var params: [String: Any] {
        switch self {
        case .orchestrator(let repo): return ["orchestrator": repo]
        case .worker(let id): return ["id": id]
        }
    }
}

/// Remembers which Needs were already announced, so each one notifies exactly once.
public struct NeedTracker: Sendable {
    private var seen: Set<String> = []
    private var primed = false

    public init() {}

    /// Needs not seen before. The first snapshot only primes: what was already waiting when the
    /// app opened is shown in the inbox, not re-announced.
    public mutating func fresh(in needs: [Need]) -> [Need] {
        let new = needs.filter { !seen.contains($0.id) }
        seen.formUnion(needs.map(\.id))
        if !primed {
            primed = true
            return []
        }
        return new
    }
}

/// "45s", "3m", "2h".
public func formatAge(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    return "\(seconds / 3600)h"
}
