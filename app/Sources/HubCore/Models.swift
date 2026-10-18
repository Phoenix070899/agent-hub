import Foundation

/// One of a repo's agents: an Orchestrator, or a Normal session (plain Claude Code).
public struct Agent: Decodable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Decodable, Sendable {
        case orchestrator
        case claude

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .orchestrator
        }
    }

    public let id: Int
    public let kind: Kind
    /// What the human called it, or what their first request was about; nil until then.
    public let name: String?
    public let model: String?
    public let live: Bool

    public init(id: Int, kind: Kind, name: String? = nil, model: String? = nil, live: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.model = model
        self.live = live
    }

    public var isOrchestrator: Bool { kind == .orchestrator }

    /// Its name, or until the first request names it, what it is and its id ("Orchestrator a3",
    /// as `hub attach a3` reads), so two unnamed ones read apart.
    public var displayName: String { name ?? "\(isOrchestrator ? "Orchestrator" : "Claude Code") a\(id)" }
}

/// One agent's share of a repo's ledger: what it is waiting on, and its Workers.
public struct AgentGroup: Identifiable, Equatable, Sendable {
    public let agent: Agent
    public let needs: [Need]
    public let running: [WorkerRow]
    public let settled: [WorkerRow]

    public var id: Int { agent.id }
}

/// One repo as the daemon's `events` stream draws it: its agents, their Workers, what needs you.
public struct Snapshot: Decodable, Equatable, Sendable {
    public struct Orchestrator: Decodable, Equatable, Sendable {
        public let live: Bool
        /// The model the human picked for this session; nil means the `claude` default.
        public let model: String?

        public init(live: Bool, model: String? = nil) {
            self.live = live
            self.model = model
        }
    }

    public let repo: String
    /// The repo's first Orchestrator, as older daemons describe it.
    public let orchestrator: Orchestrator
    /// Every open agent, oldest first; nil from a daemon older than agents.
    public let agents: [Agent]?
    /// The repo's open shells, multiplexer shells included.
    public let shells: [Int]?
    public let workers: [WorkerRow]
    public let needs: [Need]
    /// Account-wide; every session's snapshot carries the same.
    public let usage: Usage?

    public init(
        repo: String, orchestrator: Orchestrator, agents: [Agent]? = nil, shells: [Int]? = nil, workers: [WorkerRow],
        needs: [Need], usage: Usage? = nil
    ) {
        self.repo = repo
        self.orchestrator = orchestrator
        self.agents = agents
        self.shells = shells
        self.workers = workers
        self.needs = needs
        self.usage = usage
    }

    public static func empty(repo: String) -> Snapshot {
        Snapshot(repo: repo, orchestrator: Orchestrator(live: false), workers: [], needs: [])
    }

    public var needsYouCount: Int { needs.count }

    /// The ledger, one group per agent. A Worker or Need whose Orchestrator is gone, or that
    /// predates agents, belongs to the first Orchestrator.
    public var groups: [AgentGroup] {
        let list = agents ?? []
        let ids = Set(list.map(\.id))
        let first = list.first(where: \.isOrchestrator)?.id
        func owner(_ agent: Int?) -> Int? {
            if let agent, ids.contains(agent) { return agent }
            return first
        }
        let running = running
        let settled = settled
        return list.map { agent in
            AgentGroup(
                agent: agent,
                needs: needs.filter { owner($0.agent) == agent.id },
                running: running.filter { owner($0.agent) == agent.id },
                settled: settled.filter { owner($0.agent) == agent.id }
            )
        }
    }

    public func agent(_ id: Int) -> Agent? { agents?.first { $0.id == id } }

    /// The ledger's Running rows: live Workers with nothing waiting on the human, the
    /// longest-quiet first so a stuck one rises to the top.
    public var running: [WorkerRow] {
        let waiting = Set(needs.compactMap(\.worker))
        return workers
            .filter { $0.isActive && !waiting.contains($0.id) }
            .sorted { $0.quietSeconds > $1.quietSeconds }
    }

    /// The ledger's Done section: settled Workers, failed and blocked ones first, then newest.
    public var settled: [WorkerRow] {
        workers
            .filter { !$0.isActive }
            .sorted { ($0.isTrouble ? 0 : 1, $0.quietSeconds) < ($1.isTrouble ? 0 : 1, $1.quietSeconds) }
    }
}

/// The Claude account's plan limits, as `claude -p /usage` prints them.
public struct Usage: Decodable, Equatable, Sendable {
    /// One limit, e.g. "Session" 48% resetting "Oct 17 at 4:50pm".
    public struct Limit: Decodable, Equatable, Sendable, Identifiable {
        public let name: String
        public let percent: Int
        public let resets: String?

        public var id: String { name }
    }

    public let limits: [Limit]
    public let updatedAt: Int?
    public let error: String?
    public let refreshing: Bool
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
    /// From the Worker's Agent Profile.
    public let model: String?
    public let effort: String?
    /// The first line of the Worker's latest status message.
    public let progress: String?
    /// The Orchestrator that started it.
    public let agent: Int?
    /// When it settled (Unix seconds); nil while it works.
    public let settledAt: Int?

    /// The daemon's numeric id, as `decide` and `attach` take it.
    public var number: Int? { Int(id.dropFirst()) }

    /// Still working on its Task: starting or running, waiting on the human or not.
    public var isActive: Bool { phase == "starting" || phase == "running" }

    /// Settled badly: blocked, exited without a Final Report, or lost.
    public var isTrouble: Bool { !isActive && phase != "done" }

    /// "claude-sonnet-5-5, high effort".
    public var modelLine: String? {
        guard let model else { return nil }
        return effort.map { "\(model), \($0) effort" } ?? model
    }
}

/// Something only the human can settle: a Worker's question or a waiting prompt, or a Normal
/// session's own permission prompt.
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
    /// The agent it belongs to: the Worker's Orchestrator, or the Normal session itself.
    public let agent: Int?
    /// The Worker asking; nil for a Normal session's own prompt.
    public let worker: String?
    public let profile: String
    public let title: String
    public let body: String
    /// For a permission prompt: its own lines, ending in "Do you want to ...".
    public let prompt: String?
    public let at: Int

    public var id: String {
        worker == nil ? "\(kind.rawValue)-agent-\(agent ?? 0)-\(at)" : "\(kind.rawValue)-\(message)"
    }

    /// A permission prompt's own lines without the closing question the buttons answer.
    public var promptLines: [String] {
        (prompt ?? "").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Do you want") }
    }

    /// What a permission prompt asks to run: its lines after the tool's name ("Bash command"),
    /// on one line. Falls back to the whole prompt when it has a single line.
    public var command: String? {
        let lines = promptLines
        guard !lines.isEmpty else { return nil }
        return (lines.count > 1 ? lines.dropFirst() : lines[...]).joined(separator: " ")
    }
}

/// A repo the daemon knows, with its agents.
public struct SessionInfo: Decodable, Equatable, Identifiable, Sendable {
    public let repo: String
    /// Whether any of its agents is live.
    public let live: Bool
    public let model: String?
    public let agents: [Agent]?

    public init(repo: String, live: Bool, model: String? = nil, agents: [Agent]? = nil) {
        self.repo = repo
        self.live = live
        self.model = model
        self.agents = agents
    }

    public var id: String { repo }
    public var name: String { URL(fileURLWithPath: repo).lastPathComponent }

    /// Only Normal sessions, no Orchestrator: its tab gets the prompt mark.
    public var isNormalOnly: Bool {
        guard let agents, !agents.isEmpty else { return false }
        return agents.allSatisfy { !$0.isOrchestrator }
    }
}

/// What a terminal view shows.
public enum TerminalTarget: Hashable, Sendable {
    /// An Orchestrator or a Normal session.
    case agent(id: Int)
    case worker(id: Int)
    /// A shell the daemon runs for the human, e.g. the multiplexer around an agent.
    case shell(id: Int)

    /// The daemon's way of naming it in `attach` and `terminal.resize`.
    public var params: [String: Any] {
        switch self {
        case .agent(let id): return ["agent": id]
        case .worker(let id): return ["id": id]
        case .shell(let id): return ["shell": id]
        }
    }

    /// `a3`, `w21`, `s7`: how `hub attach` and multiplexer session names call it.
    public var label: String {
        switch self {
        case .agent(let id): return "a\(id)"
        case .worker(let id): return "w\(id)"
        case .shell(let id): return "s\(id)"
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

/// "1 Worker running", "3 Workers at work": a count of Workers and what they are doing.
public func workers(_ count: Int, _ doing: String) -> String {
    "\(count) Worker\(count == 1 ? "" : "s") \(doing)"
}

/// The byte a tmux key like "C-b" sends, for typing the prefix into a terminal; nil for keys
/// that are not a plain Ctrl-letter (tmux's own notation, as `tmux show -gv prefix` prints it).
public func tmuxControlByte(_ key: String) -> UInt8? {
    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    if key == "C-Space" || key == "C-@" { return 0 }
    guard key.count == 3, key.hasPrefix("C-"), let letter = key.last?.asciiValue,
          (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(letter) else { return nil }
    return letter & 0x1f
}

/// How well `query` matches `text` for Quick open, higher first; nil when it does not. A word
/// that starts with the query beats the query inside a word, which beats its letters in order
/// ("rfu" finds "Rerank follow-ups"). Case is ignored; an empty query matches everything.
public func quickOpenScore(_ query: String, _ text: String) -> Int? {
    let query = query.lowercased().trimmingCharacters(in: .whitespaces)
    let text = text.lowercased()
    guard !query.isEmpty else { return 0 }
    if text.hasPrefix(query) { return 3 }
    if let range = text.range(of: query) {
        let before = range.lowerBound == text.startIndex ? " " : text[text.index(before: range.lowerBound)]
        return before.isLetter || before.isNumber ? 1 : 2
    }
    var rest = Substring(text)
    for character in query where character != " " {
        guard let found = rest.firstIndex(of: character) else { return nil }
        rest = rest[rest.index(after: found)...]
    }
    return 0
}

/// Dropped files as Terminal.app types them: each path with shell-special characters
/// backslash-escaped, separated by spaces, and a space after so typing can go on.
public func droppedPaths(_ paths: [String]) -> String {
    let plain = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+,@%=:")
    let escaped = paths.map { path in
        path.map { plain.contains($0) || !$0.isASCII ? String($0) : "\\\($0)" }.joined()
    }
    return escaped.joined(separator: " ") + " "
}

/// A GitHub issue as `gh issue view --json number,title,body,url` prints it, to start an agent on.
public struct GitHubIssue: Decodable, Equatable, Sendable {
    public let number: Int
    public let title: String
    public let body: String
    public let url: String

    /// The agent's name in the ledger: "#12 Flaky bench".
    public var name: String { "#\(number) \(title)" }

    /// The agent's first message: the whole issue, and what to do with it.
    public var request: String {
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Work on GitHub issue #\(number): \(title)\n\(url)\n\n\(body.isEmpty ? "(The issue has no description.)" : body)"
    }
}

/// What `gh issue view` takes for an issue typed by hand: its URL, or its number with or without "#".
/// Nil for anything else.
public func issueReference(_ typed: String) -> String? {
    let text = typed.trimmingCharacters(in: .whitespaces)
    let number = text.hasPrefix("#") ? String(text.dropFirst()) : text
    if !number.isEmpty, number.allSatisfy(\.isASCII), Int(number) != nil { return number }
    if let url = URL(string: text), url.host == "github.com", url.pathComponents.count >= 5,
       url.pathComponents[3] == "issues", Int(url.pathComponents[4]) != nil {
        return text
    }
    return nil
}
