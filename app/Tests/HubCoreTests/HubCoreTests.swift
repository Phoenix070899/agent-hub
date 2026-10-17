import Foundation
import Testing
@testable import HubCore

/// A snapshot exactly as the daemon's `events` stream prints it.
let snapshotLine = """
{"repo":"/r","orchestrator":{"live":true},"workers":[{"id":"w3","profile":"bash","title":"Remove junk",\
"state":"needs you","phase":"running","quietSeconds":75,"place":"in place","branch":null,"live":true,\
"blocker":"permission_prompt","openQuestions":[],"finalReport":null}],"needs":[{"kind":"permission_prompt",\
"message":9,"worker":"w3","profile":"bash","title":"Remove junk","body":"Blocked: permission_prompt",\
"prompt":"Bash command\\nrm -rf junk\\nDo you want to proceed?","at":1792200000},{"kind":"something_new",\
"message":10,"worker":"w3","profile":"bash","title":"Remove junk","body":"?","prompt":"","at":1792200001}]}
"""

@Test func decodesTheDaemonSnapshot() throws {
    let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(snapshotLine.utf8))
    #expect(snapshot.orchestrator.live)
    #expect(snapshot.workers[0].state == .needsYou)
    #expect(snapshot.workers[0].number == 3)
    #expect(snapshot.needs[0].kind == .permissionPrompt)
    #expect(snapshot.needs[0].prompt?.hasSuffix("Do you want to proceed?") == true)
    #expect(snapshot.needs[1].kind == .other, "unknown kinds still decode")
    #expect(snapshot.needsYouCount == 2)
}

@Test func needsAnnounceOnceAndNotWhatWasWaitingAtLaunch() throws {
    let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(snapshotLine.utf8))
    var tracker = NeedTracker()
    #expect(tracker.fresh(in: [snapshot.needs[0]]).isEmpty)
    #expect(tracker.fresh(in: snapshot.needs).map(\.message) == [10])
    #expect(tracker.fresh(in: snapshot.needs).isEmpty)
}

@Test func agesAreShort() {
    #expect(formatAge(45) == "45s")
    #expect(formatAge(180) == "3m")
    #expect(formatAge(7200) == "2h")
}

/// The real `hub` binary with the daemon tests' fake agent, in a throwaway state folder.
struct LiveDaemon {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let state = "/tmp/hubs-\(ProcessInfo.processInfo.processIdentifier)-\(Int.random(in: 0..<100000))"
    var repo: String { state + "/repo" }
    var client: DaemonClient { DaemonClient(socketPath: state + "/hubd.sock") }

    @discardableResult
    func run(_ args: [String], in dir: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = root.appendingPathComponent("target/release/hub")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: dir ?? repo)
        var env = ProcessInfo.processInfo.environment
        env["HUB_STATE"] = state
        env["HUB_TEST_AGENT"] = root.appendingPathComponent("crates/hub/tests/fake-agent.sh").path
        env["PATH"] = root.appendingPathComponent("target/release").path + ":" + (env["PATH"] ?? "")
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func setUp() throws {
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        for args in [["init", "-q"], ["commit", "-q", "--allow-empty", "-m", "init"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["-c", "user.name=t", "-c", "user.email=t@t"] + args
            git.currentDirectoryURL = URL(fileURLWithPath: repo)
            try git.run()
            git.waitUntilExit()
        }
    }

    func tearDown() {
        _ = try? run(["shutdown", "--force"])
        try? FileManager.default.removeItem(atPath: state)
    }
}

@Test(.timeLimit(.minutes(1))) func followsAWorkerAndApprovesItsPrompt() throws {
    let hub = LiveDaemon()
    try hub.setUp()
    defer { hub.tearDown() }
    try hub.run(["worker", "start", "bash", "--spec", "prompt me"])
    let repo = URL(fileURLWithPath: hub.repo).resolvingSymlinksInPath().path

    var waiting: Need?
    let socket = try hub.client.open("events", ["repo": repo])
    _ = try DaemonClient.result(of: socket.readLine())
    while waiting == nil {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: socket.readLine())
        waiting = snapshot.needs.first { $0.kind == .permissionPrompt }
    }
    socket.shutdown()
    #expect(waiting?.prompt == "Bash command\nrm -rf junk\nDo you want to proceed?")

    try hub.client.decide(worker: 1, approve: true)
    let terminal = try hub.client.attach(.worker(id: 1), rows: 30, cols: 100)
    var screen = ""
    while !screen.contains("approved"), let chunk = try terminal.readChunk() {
        screen += String(decoding: chunk, as: UTF8.self)
    }
    terminal.shutdown()
    #expect(screen.contains("approved"))
    #expect(try hub.client.sessions().isEmpty)
}
