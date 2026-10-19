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

    public func resize(_ target: TerminalTarget, rows: Int, cols: Int) throws {
        var params = target.params
        params["rows"] = rows
        params["cols"] = cols
        try call("terminal.resize", params)
    }

    /// Starts a new agent in a repo: an Orchestrator or a Normal session, with an optional name and
    /// model. Returns the repo's key as the daemon names it, and the new agent's id.
    public func openAgent(repo: String, kind: Agent.Kind, name: String? = nil, model: String? = nil,
                          request: String? = nil) throws -> (repo: String, agent: Int)
    {
        var params: [String: Any] = ["repo": repo, "kind": kind.rawValue]
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

    /// The human's multiplexer around an agent's or a Worker's terminal: `command` runs with
    /// `{session}`, `{dir}` and `{command}` filled in. Returns the shell to attach to; asking again
    /// returns the same one while it lives.
    /// The shell running the multiplexer around `target`, and the multiplexer session it opened.
    public func openMux(_ target: TerminalTarget, command: String) throws -> (shell: Int, session: String?) {
        var params = target.params
        params["command"] = command
        let result = try call("mux.open", params) as? [String: Any]
        guard let shell = result?["shell"] as? Int else { throw HubError.badResponse }
        return (shell, result?["session"] as? String)
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
