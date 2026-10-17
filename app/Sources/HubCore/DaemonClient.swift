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

    public func openSession(repo: String) throws {
        try call("session.open", ["repo": repo])
    }

    public func decide(worker: Int, approve: Bool, note: String? = nil) throws {
        var params: [String: Any] = ["worker": worker, "approve": approve]
        if let note, !note.isEmpty { params["note"] = note }
        try call("decide", params)
    }

    public func reply(message: Int, text: String) throws {
        try call("reply", ["id": message, "body": text, "by_human": true])
    }
}
