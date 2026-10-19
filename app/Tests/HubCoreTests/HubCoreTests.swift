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
"message":10,"worker":"w3","profile":"bash","title":"Remove junk","body":"?","prompt":"","at":1792200001}],"usage":{"limits":[{"name":"Session","percent":48,"resets":"Oct 17 at 4:50pm"},\
{"name":"Week (Fable)","percent":0,"resets":null}],"updatedAt":1792199000,"error":null,"refreshing":false}}
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
    #expect(snapshot.usage?.limits.map(\.name) == ["Session", "Week (Fable)"])
    #expect(snapshot.usage?.limits.first?.percent == 48)
    #expect(snapshot.usage?.limits.last?.resets == nil)
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

@Test func tmuxPrefixesBecomeControlBytes() {
    #expect(tmuxControlByte("C-b\n") == 0x02)
    #expect(tmuxControlByte("C-a") == 0x01)
    #expect(tmuxControlByte("C-Space") == 0x00)
    #expect(tmuxControlByte("M-a") == nil)
    #expect(tmuxControlByte("None") == nil)
}

@Test func quickOpenRanksWordStartsFirst() {
    #expect(quickOpenScore("rer", "Rerank follow-ups")! > quickOpenScore("follow", "Rerank follow-ups")!)
    #expect(quickOpenScore("follow", "Rerank follow-ups")! > quickOpenScore("ollow", "Rerank follow-ups")!)
    #expect(quickOpenScore("rfu", "Rerank follow-ups") != nil)
    #expect(quickOpenScore("zzz", "Rerank follow-ups") == nil)
    #expect(quickOpenScore("", "anything") == 0)
}

@Test func droppedPathsAreEscapedLikeTerminal() {
    #expect(droppedPaths(["/tmp/a.png"]) == "/tmp/a.png ")
    #expect(droppedPaths(["/Users/me/My Shot (1).png", "/tmp/b"]) == "/Users/me/My\\ Shot\\ \\(1\\).png /tmp/b ")
    #expect(droppedPaths(["/tmp/it's"]) == "/tmp/it\\'s ")
}

@Test func issuesAreTypedAsANumberOrAURL() {
    #expect(issueReference("12") == "12")
    #expect(issueReference(" #12 ") == "12")
    #expect(issueReference("https://github.com/o/r/issues/12") == "https://github.com/o/r/issues/12")
    #expect(issueReference("https://github.com/o/r/pull/12") == nil)
    #expect(issueReference("fix the bench") == nil)
    #expect(issueReference("#") == nil)
}

@Test func anIssueBecomesTheFirstRequest() throws {
    let json = #"{"number":12,"title":"Flaky bench","body":"It fails 1 in 5.\n","url":"https://github.com/o/r/issues/12"}"#
    let issue = try JSONDecoder().decode(GitHubIssue.self, from: Data(json.utf8))
    #expect(issue.name == "#12 Flaky bench")
    #expect(issue.request == "Work on GitHub issue #12: Flaky bench\nhttps://github.com/o/r/issues/12\n\nIt fails 1 in 5.")
}

let workerDiff = """
diff --git a/README.md b/README.md
index 9daeafb..4f1c2e1 100644
--- a/README.md
+++ b/README.md
@@ -1,3 +1,3 @@
 # test
-old line
+worker line
 end
\\ No newline at end of file
diff --git a/notes.txt b/notes.txt
new file mode 100644
index 0000000..3b18e51
--- /dev/null
+++ b/notes.txt
@@ -0,0 +1 @@
+new file
diff --git a/logo.png b/logo.png
deleted file mode 100644
Binary files a/logo.png and /dev/null differ

"""

@Test func aDiffSplitsIntoFilesWithLineNumbers() {
    let files = parseDiff(workerDiff)
    #expect(files.map(\.path) == ["README.md", "notes.txt", "logo.png"])
    #expect(files.map(\.change) == [.modified, .added, .deleted])
    let readme = files[0]
    #expect(readme.additions == 1 && readme.deletions == 1)
    #expect(readme.lines[1] == DiffLine(kind: .context, text: "# test", old: 1, new: 1))
    #expect(readme.lines[2] == DiffLine(kind: .removed, text: "old line", old: 2))
    #expect(readme.lines[3] == DiffLine(kind: .added, text: "worker line", new: 2))
    #expect(readme.lines[4] == DiffLine(kind: .context, text: "end", old: 3, new: 3))
    #expect(readme.lines[5].kind == .note)
    #expect(files[1].lines.last == DiffLine(kind: .added, text: "new file", new: 1))
    #expect(files[2].binary && files[2].lines.isEmpty)
}

@Test func aReviewQuotesEachCommentedLine() {
    let files = parseDiff(workerDiff)
    let body = reviewBody([
        ReviewComment(path: "README.md", line: files[0].lines[3], text: "Say why. "),
        ReviewComment(path: "README.md", line: files[0].lines[2], text: "Keep this"),
    ])
    #expect(body == "README.md:2\n> worker line\nSay why.\n\nREADME.md:2 (removed)\n> old line\nKeep this")
}

@Test func aFanoutBranchIsNamedAfterItsTask() {
    #expect(fanoutBranch("Fix the flaky bench!") == "feat/fix-the-flaky-bench")
    #expect(fanoutBranch("Ünïcode & spaces  ") == "feat/n-code-spaces")
    #expect(fanoutBranch("???") == "feat/task")
    #expect(fanoutBranch(String(repeating: "word ", count: 20)).count <= 45)
}

@Test func oneWorkerIsSingular() {
    #expect(workers(1, "running") == "1 Worker running")
    #expect(workers(3, "at work") == "3 Workers at work")
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

/// One Worker row with the fields the ledger reads.
func row(_ id: String, phase: String, quiet: Int, model: String? = nil, effort: String? = nil, agent: Int? = nil) -> String {
    let model = model.map { "\"\($0)\"" } ?? "null"
    let effort = effort.map { "\"\($0)\"" } ?? "null"
    let agent = agent.map(String.init) ?? "null"
    return """
    {"id":"\(id)","profile":"naruto","title":"t","state":"running","phase":"\(phase)","quietSeconds":\(quiet),\
    "place":"in place","branch":null,"live":true,"blocker":null,"openQuestions":[],"finalReport":null,\
    "model":\(model),"effort":\(effort),"progress":null,"agent":\(agent)}
    """
}

@Test func decodesModelsAndProgress() throws {
    let line = """
    {"repo":"/r","orchestrator":{"live":true,"model":"claude-opus-5-5"},"workers":[{"id":"w14","profile":"naruto",\
    "title":"Fix rerank","state":"running","phase":"running","quietSeconds":120,"place":"worktree lanh-rerank",\
    "branch":"lanh-rerank","live":true,"blocker":null,"openQuestions":[],"finalReport":null,\
    "model":"claude-sonnet-5-5","effort":"high","progress":"41 of 44 tests passing"}],"needs":[]}
    """
    let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(line.utf8))
    #expect(snapshot.orchestrator.model == "claude-opus-5-5")
    #expect(snapshot.workers[0].progress == "41 of 44 tests passing")
    #expect(snapshot.workers[0].modelLine == "claude-sonnet-5-5, high effort")
    let old = try JSONDecoder().decode(Snapshot.self, from: Data(snapshotLine.utf8))
    #expect(old.orchestrator.model == nil, "a daemon without models still decodes")
    #expect(old.workers[0].modelLine == nil)
}

@Test func theLedgerSplitsRunningFromSettled() throws {
    let line = """
    {"repo":"/r","orchestrator":{"live":true},"workers":[\(row("w1", phase: "running", quiet: 30)),\
    \(row("w2", phase: "running", quiet: 400)),\(row("w3", phase: "done", quiet: 900)),\
    \(row("w4", phase: "blocked", quiet: 4000)),\(row("w5", phase: "done", quiet: 60)),\
    \(row("w6", phase: "running", quiet: 10))],"needs":[{"kind":"question","message":1,"worker":"w6",\
    "profile":"naruto","title":"t","body":"Which?","prompt":null,"at":1}]}
    """
    let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(line.utf8))
    #expect(snapshot.running.map(\.id) == ["w2", "w1"], "longest quiet first; w6 waits on the human")
    #expect(snapshot.settled.map(\.id) == ["w4", "w5", "w3"], "trouble first, then newest")
}

@Test func theLedgerGroupsByAgent() throws {
    let line = """
    {"repo":"/r","orchestrator":{"live":true},"agents":[{"id":1,"kind":"orchestrator","name":"Rerank","model":null,"live":true},\
    {"id":2,"kind":"orchestrator","name":null,"model":"claude-opus-5-5","live":false},\
    {"id":3,"kind":"claude","name":null,"model":null,"live":true}],\
    "workers":[\(row("w1", phase: "running", quiet: 30, agent: 2)),\(row("w2", phase: "done", quiet: 9, agent: 1)),\
    \(row("w3", phase: "running", quiet: 5, agent: nil)),\(row("w4", phase: "running", quiet: 5, agent: 99))],\
    "needs":[{"kind":"permission_prompt","message":0,"agent":3,"worker":null,"profile":"claude","title":"Claude Code",\
    "body":"","prompt":"Bash command\\nmake app\\nDo you want to proceed?","at":5}]}
    """
    let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(line.utf8))
    let groups = snapshot.groups
    #expect(groups.map(\.agent.id) == [1, 2, 3])
    #expect(groups[0].running.map(\.id) == ["w3", "w4"], "Workers of no known agent go to the first Orchestrator")
    #expect(groups[0].settled.map(\.id) == ["w2"])
    #expect(groups[1].running.map(\.id) == ["w1"])
    #expect(groups[2].needs.first?.command == "make app")
    #expect(groups[2].needs.first?.worker == nil)
    #expect(groups[1].agent.displayName == "Orchestrator a2")
    #expect(groups[2].agent.displayName == "Claude Code a3")
}

@Test func aPermissionPromptNamesItsCommand() throws {
    let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(snapshotLine.utf8))
    #expect(snapshot.needs[0].promptLines == ["Bash command", "rm -rf junk"])
    #expect(snapshot.needs[0].command == "rm -rf junk")
    #expect(snapshot.needs[1].command == nil)
}

@Test func themeColoursRoundTripThroughHex() throws {
    let rgb = try #require(TerminalTheme.rgb("#0a0e14"))
    #expect(TerminalTheme.hex(red: rgb.red, green: rgb.green, blue: rgb.blue) == "#0a0e14")
    #expect(TerminalTheme.rgb("0a0e14") != nil)
    #expect(TerminalTheme.rgb("#zzz") == nil)
    for theme in TerminalTheme.presets {
        #expect(theme.ansi.count == 16, "\(theme.name) has 16 ANSI colours")
        #expect(([theme.background, theme.foreground, theme.cursor, theme.selection] + theme.ansi).allSatisfy { TerminalTheme.rgb($0) != nil })
    }
    #expect(TerminalAppearance.orca.theme == .ayuDark)
}

@Test func theWindowFollowsTheTerminalBackground() {
    #expect(TerminalTheme.ayuDark.isDark)
    var light = TerminalTheme.ayuDark
    light.background = "#fbfcfd"
    #expect(!light.isDark)
}

@Test func terminalTargetsNameThemselvesLikeHubAttach() {
    #expect(TerminalTarget.agent(id: 3).label == "a3")
    #expect(TerminalTarget.worker(id: 21).label == "w21")
    #expect(TerminalTarget.shell(id: 7).params["shell"] as? Int == 7)
}
