import Foundation

/// Talks to the Hub Daemon the way the `hub` CLI does: one JSON line each way, or a stream.
public struct DaemonClient: Sendable {
    public let socketPath: String

    public init(socketPath: String = DaemonClient.defaultSocketPath()) {
        self.socketPath = socketPath
    }

    /// `$HUB_STATE/hubd.sock`, else `~/.agent-hub/hubd.sock`.
    public static func defaultSocketPath() -> String {
        if let state = ProcessInfo.processInfo.environment["HUB_STATE"], !state.isEmpty {
            return state + "/hubd.sock"
        }
        return NSHomeDirectory() + "/.agent-hub/hubd.sock"
    }

    /// Opens a connection and sends the request line; the caller reads the response.
    public func open(_ method: String, _ params: [String: Any] = [:]) throws -> HubSocket {
        let socket = try HubSocket(path: socketPath)
        try socket.writeLine(["method": method, "params": params])
        return socket
    }

    /// One request, one response: the `result`, or the daemon's error.
    @discardableResult
    public func call(_ method: String, _ params: [String: Any] = [:]) throws -> Any {
        let socket = try open(method, params)
        return try Self.result(of: socket.readLine())
    }

    public static func result(of line: Data) throws -> Any {
        guard let response = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw HubError.badResponse
        }
        if response["ok"] as? Bool == true {
            return response["result"] ?? [:]
        }
        throw HubError.daemon(response["error"] as? String ?? "the Hub Daemon refused the request")
    }

    public func sessions() throws -> [SessionInfo] {
        let result = try call("sessions.list")
        let data = try JSONSerialization.data(withJSONObject: (result as? [String: Any])?["sessions"] ?? [])
        return try JSONDecoder().decode([SessionInfo].self, from: data)
    }

    /// Follows a Hub Session: calls `onSnapshot` for each snapshot until the connection ends.
    public func follow(repo: String, onSnapshot: (Snapshot) -> Void) throws {
        let socket = try open("events", ["repo": repo])
        _ = try Self.result(of: socket.readLine())
        while true {
            let line = try socket.readLine()
            onSnapshot(try JSONDecoder().decode(Snapshot.self, from: line))
        }
    }

    /// Attaches to a terminal: after this, the socket carries raw terminal bytes both ways.
    public func attach(_ target: TerminalTarget, rows: Int, cols: Int) throws -> HubSocket {
        var params = target.params
        params["rows"] = rows
        params["cols"] = cols
        let socket = try open("attach", params)
        _ = try Self.result(of: socket.readLine())
        return socket
    }

    /// Types `text` into a terminal exactly as given: a dropped path, a note, tmux keys.
    public func write(_ target: TerminalTarget, text: String) throws {
        var params = target.params
        params["text"] = text
        try call("terminal.write", params)
    }

    /// The `hub` the daemon runs as, which Echo's terminal panes run to attach.
    public func hubExecutable() throws -> String {
        guard let exe = (try call("ping") as? [String: Any])?["exe"] as? String else { throw HubError.badResponse }
        return exe
    }

    public func resize(_ target: TerminalTarget, rows: Int, cols: Int) throws {
        var params = target.params
        params["rows"] = rows
        params["cols"] = cols
        try call("terminal.resize", params)
    }

    /// Starts a new agent in a repo: an Orchestrator or a Normal session, with an optional name and
    /// model. Returns the repo's key as the daemon names it, and the new agent's id.
    /// Starts a new agent. `branch` puts it on an existing branch; `newBranch` on a new branch
    /// from `base`, in its own worktree; neither, in the repo's checkout.
    public func openAgent(repo: String, kind: Agent.Kind, name: String? = nil, model: String? = nil,
                          request: String? = nil, branch: String? = nil, newBranch: String? = nil,
                          base: String? = nil) throws -> (repo: String, agent: Int)
    {
        var params: [String: Any] = ["repo": repo, "kind": kind.rawValue]
        if let branch { params["branch"] = branch }
        if let newBranch { params["new_branch"] = newBranch }
        if let base, !base.isEmpty { params["base"] = base }
        if let name, !name.isEmpty { params["name"] = name }
        if let model, !model.isEmpty { params["model"] = model }
        if let request, !request.isEmpty { params["request"] = request }
        let result = try call("agent.open", params) as? [String: Any]
        guard let agent = result?["agent"] as? Int else { throw HubError.badResponse }
        return (result?["repo"] as? String ?? repo, agent)
    }

    /// Starts a stopped agent again, resuming its conversation.
    public func startAgent(_ id: Int) throws {
        try call("agent.open", ["agent": id])
    }

    /// Stops an agent's terminal; it stays in the ledger, ready to start again.
    public func stopAgent(_ id: Int) throws {
        try call("agent.close", ["agent": id])
    }

    /// Stops an agent and takes it out of the ledger.
    public func forgetAgent(_ id: Int) throws {
        try call("agent.forget", ["agent": id])
    }

    public func renameAgent(_ id: Int, to name: String) throws {
        try call("agent.rename", ["agent": id, "name": name])
    }

    /// The human's multiplexer around an agent's or a Worker's terminal: `command` with
    /// `{session}`, `{dir}` and `{command}` filled in, as the line a pane runs (`hub mux`), and the
    /// multiplexer session it opens.
    public func muxCommand(_ target: TerminalTarget, command: String) throws -> (command: String, session: String?) {
        var params = target.params
        params["command"] = command
        let result = try call("mux.command", params) as? [String: Any]
        guard let line = result?["command"] as? String else { throw HubError.badResponse }
        return (line, result?["session"] as? String)
    }

    /// Stops a Worker and closes its terminal.
    public func closeWorker(_ id: Int) throws {
        try call("worker.close", ["id": id])
    }

    /// Takes a settled Worker off Echo's Done list; the Orchestrator's view is unchanged.
    public func dismissWorker(_ id: Int) throws {
        try call("worker.dismiss", ["id": id])
    }

    /// What a Worker changed: its diff, and whether the daemon cut it short.
    public func workerDiff(_ id: Int) throws -> (diff: String, truncated: Bool) {
        let result = try call("worker.diff", ["id": id]) as? [String: Any]
        guard let diff = result?["diff"] as? String else { throw HubError.badResponse }
        return (diff, result?["truncated"] as? Bool ?? false)
    }

    /// The repo's checked-out branch and its local branches, newest first.
    public func branches(repo: String) throws -> (current: String, branches: [RepoBranch]) {
        let result = try call("branches.list", ["repo": repo]) as? [String: Any]
        let data = try JSONSerialization.data(withJSONObject: result?["branches"] ?? [])
        return (result?["current"] as? String ?? "", try JSONDecoder().decode([RepoBranch].self, from: data))
    }

    public func profiles() throws -> [WorkerProfile] {
        let result = try call("profiles.list") as? [String: Any]
        let data = try JSONSerialization.data(withJSONObject: result?["profiles"] ?? [])
        return try JSONDecoder().decode([WorkerProfile].self, from: data)
    }

    /// Starts `count` Workers on one Task, each in its own worktree on `<branch>-<n>`. Returns
    /// their ids, and why any of them could not start.
    public func fanOut(repo: String, agent: Int?, profile: String, title: String, spec: String,
                       branch: String, count: Int) throws -> (workers: [String], failed: [String]) {
        var params: [String: Any] = ["repo": repo, "profile": profile, "title": title, "spec": spec,
                                     "branch": branch, "count": count]
        if let agent { params["agent"] = agent }
        let result = try call("worker.fanout", params) as? [String: Any]
        return (result?["workers"] as? [String] ?? [], result?["failed"] as? [String] ?? [])
    }

    /// Keeps one try of a fan-out: merges its branch, closes the others. Returns the branch and
    /// the branch it went into.
    public func pickWorker(_ id: Int) throws -> (branch: String, into: String) {
        let result = try call("worker.pick", ["id": id]) as? [String: Any]
        return (result?["branch"] as? String ?? "", result?["into"] as? String ?? "")
    }

    /// Sends the human's review of a Worker's changes to the Worker itself or its Orchestrator.
    public func reviewWorker(_ id: Int, toWorker: Bool, body: String) throws {
        try call("worker.review", ["id": id, "to": toWorker ? "worker" : "orchestrator", "body": body])
    }

    public func decide(worker: Int, approve: Bool, note: String? = nil) throws {
        var params: [String: Any] = ["worker": worker, "approve": approve]
        if let note, !note.isEmpty { params["note"] = note }
        try call("decide", params)
    }

    /// Approve or Deny on a Normal session's own permission prompt.
    public func decide(agent: Int, approve: Bool, note: String? = nil) throws {
        var params: [String: Any] = ["agent": agent, "approve": approve]
        if let note, !note.isEmpty { params["note"] = note }
        try call("decide", params)
    }

    public func reply(message: Int, text: String) throws {
        try call("reply", ["id": message, "body": text, "by_human": true])
    }
}
