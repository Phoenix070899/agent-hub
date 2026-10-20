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

@Test func theSmartFieldTellsIssuesBranchesAndNamesApart() {
    let branches = ["main", "fix/old"]
    #expect(smartCreateFrom("  ", branches: branches) == nil)
    #expect(smartCreateFrom("#12", branches: branches) == .issue("#12"))
    #expect(smartCreateFrom("https://github.com/o/r/issues/7", branches: branches) == .issue("https://github.com/o/r/issues/7"))
    #expect(smartCreateFrom("fix/old", branches: branches) == .branch("fix/old"))
    #expect(smartCreateFrom("Magic link login", branches: branches) == .name("Magic link login"))
}

@Test func aFileTreeListsFoldersFirstAndOpensOnDemand() {
    let tree = FileTree(paths: ["README.md", "src/b.swift", "src/a.swift", "src/ui/View.swift", "Package.swift"])
    #expect(tree.rows(open: []).map(\.path) == ["src", "Package.swift", "README.md"])
    #expect(tree.rows(open: ["src"]).map(\.path) == ["src", "src/ui", "src/a.swift", "src/b.swift", "Package.swift", "README.md"])
    #expect(tree.rows(open: ["src", "src/ui"]).first { $0.name == "View.swift" }?.depth == 2)
    var ignored = FileTree(paths: ["a.txt"], folders: ["node_modules/"])
    #expect(ignored.rows(open: ["node_modules"]).map(\.path) == ["node_modules", "a.txt"])
    ignored.fill("node_modules", with: [("left-pad", true), ("x.js", false)])
    #expect(ignored.rows(open: ["node_modules"]).map(\.path) == ["node_modules", "node_modules/left-pad", "node_modules/x.js", "a.txt"])
}

@Test func gitStatusMarksEachPath() {
    let marks = parseGitStatus(" M src/a.swift\0A  src/new.swift\0?? notes.txt\0 D gone.txt\0R  b.swift\0old.swift\0")
    #expect(marks == ["src/a.swift": .modified, "src/new.swift": .added, "notes.txt": .untracked, "gone.txt": .deleted, "b.swift": .renamed])
    #expect(folderHasChanges("src", in: marks))
    #expect(!folderHasChanges("docs", in: marks))
}

@Test func filesAreToldApartForPreview() {
    #expect(fileKind(path: "a.png", head: Data()) == .image)
    #expect(fileKind(path: "a.pdf", head: Data()) == .pdf)
    #expect(fileKind(path: "a.bin", head: Data([0x41, 0x00, 0x42])) == .binary)
    #expect(fileKind(path: "README.md", head: Data("# hi".utf8)) == .markdown)
    #expect(fileKind(path: "main.rs", head: Data("fn main() {}".utf8)) == .text)
}

@Test func aMentionIsEscapedLikeADroppedPath() {
    #expect(mentionText("src/auth.ts") == "@src/auth.ts ")
    #expect(mentionText("docs/My Notes.md") == "@docs/My\\ Notes.md ")
}

@Test func markdownSplitsIntoBlocks() {
    let blocks = parseMarkdown("# Title\n\nOne\ntwo\n\n- a\n2. b\n> q\n---\n```sh\nls -la\n```")
    #expect(blocks == [.heading(level: 1, text: "Title"), .paragraph("One two"), .bullet("a", ordered: nil),
                       .bullet("b", ordered: 2), .quote("q"), .rule, .code("ls -la", language: "sh")])
}

@Test func changedLinesAreFoundByPosition() {
    #expect(changedLines(old: ["a", "b", "c"], new: ["a", "B", "c", "d"]) == [1, 3])
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

@Test func aLookSavedBeforeBackgroundImagesStillLoads() throws {
    var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TerminalAppearance.orca)) as! [String: Any]
    old.removeValue(forKey: "backgroundImage")
    old.removeValue(forKey: "backgroundImageDim")
    old.removeValue(forKey: "backgroundImageBlur")
    let loaded = try JSONDecoder().decode(TerminalAppearance.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(loaded == .orca)
    #expect(loaded.backgroundImage == nil)

    var withImage = TerminalAppearance.orca
    withImage.backgroundImage = "/Users/me/Pictures/sea.jpg"
    withImage.backgroundImageDim = 0.5
    withImage.backgroundImageBlur = 12
    #expect(try JSONDecoder().decode(TerminalAppearance.self, from: JSONEncoder().encode(withImage)) == withImage)
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

@Test(.timeLimit(.minutes(1))) func readsALineThatArrivesInTwoReads() throws {
    var fds: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    let socket = HubSocket(fd: fds[0])
    defer { close(fds[1]) }
    let line = Data(repeating: UInt8(ascii: "x"), count: 40 * 1024)
    let writer = Thread {
        _ = line.withUnsafeBytes { Darwin.write(fds[1], $0.baseAddress!, 1000) }
        usleep(100_000)
        var rest = line.dropFirst(1000)
        rest.append(contentsOf: "\nnext\n".utf8)
        _ = rest.withUnsafeBytes { Darwin.write(fds[1], $0.baseAddress!, $0.count) }
    }
    writer.start()
    #expect(try socket.readLine() == line)
    #expect(try socket.readLine() == Data("next".utf8))
}

@Test func usageResetsReadAsATimeLeft() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Saigon")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 11, minute: 50))!
    func left(_ resets: String?) -> String? {
        Usage.Limit(name: "Session", percent: 41, resets: resets).resetsIn(now: now, calendar: calendar)
    }
    #expect(left("Oct 19 at 3:30pm") == "3h 40m")
    #expect(left("Oct 23 at 11pm") == "4d 11h")
    #expect(left("Oct 19 at 12pm") == "10m")
    #expect(left("Jan 2 at 9am") == "74d 21h", "a date earlier in the year is next year's")
    #expect(left("soon") == nil)
    #expect(left(nil) == nil)
}

@Test func agentsCarryTheBranchCheckedOutWhereTheyWork() throws {
    let json = #"[{"id":6,"kind":"orchestrator","live":true,"head":"plan/enterprise-rag"},{"id":7,"kind":"claude","live":false}]"#
    let agents = try JSONDecoder().decode([Agent].self, from: Data(json.utf8))
    #expect(agents[0].head == "plan/enterprise-rag")
    #expect(agents[1].head == nil, "older daemons send no head")
}

@Test func ignoredFilesAndWhatIsInsideIgnoredFoldersReadAsIgnored() {
    var tree = FileTree(paths: ["src/a.swift", ".env"], folders: ["build/"], ignored: [".env", "build/"])
    tree.fill("build", with: [(name: "out.o", isFolder: false)])
    #expect(tree.isIgnored(".env"))
    #expect(tree.isIgnored("build"))
    #expect(tree.isIgnored("build/out.o"))
    #expect(!tree.isIgnored("src/a.swift"))
    #expect(!tree.isIgnored("buildings.txt"))
}

@Test func fileSearchRanksNameMatchesFirst() {
    let paths = ["docs/readme.md", "src/Search.swift", "src/search/index.ts", "app/research.txt", "Tests/x.swift"]
    #expect(searchFiles("search", in: paths) == ["src/Search.swift", "app/research.txt", "src/search/index.ts"])
    #expect(searchFiles("src swift", in: paths) == ["src/Search.swift"], "every word must match")
    #expect(searchFiles("  ", in: paths).isEmpty)
    #expect(searchFiles("s", in: paths, limit: 2).count == 2)
}

@Test func grepOutputReadsAsHitsPerFile() {
    let output = "src/a.swift\u{0}12\u{0}    let search = 1\nsrc/a.swift\u{0}40\u{0}search()\nREADME.md\u{0}3\u{0}Search here\n"
    let hits = parseGrep(output)
    #expect(hits.map(\.path) == ["src/a.swift", "src/a.swift", "README.md"])
    #expect(hits[0].line == 12)
    #expect(hits[0].text == "let search = 1", "leading space is trimmed")
    #expect(parseGrep("").isEmpty)
}

@Test func markdownFrontMatterIsMetadataNotARule() {
    let blocks = parseMarkdown("---\ntitle: Plan\nstatus: draft\n---\n# Plan\n")
    #expect(blocks == [.frontMatter("title: Plan\nstatus: draft"), .heading(level: 1, text: "Plan")])
}

@Test func markdownTables() {
    let source = """
    | Name | Count | Note |
    |:-----|------:|:----:|
    | a \\| b | `x|y` | **ok** |
    | short |
    """
    #expect(parseMarkdown(source) == [.table(
        header: ["Name", "Count", "Note"],
        rows: [["a | b", "`x|y`", "**ok**"], ["short", "", ""]],
        alignments: [.leading, .trailing, .center]
    )])
    #expect(parseMarkdown("a | b\n--- | ---\n1 | 2") == [.table(header: ["a", "b"], rows: [["1", "2"]], alignments: [.leading, .leading])])
}

@Test func markdownNestedTaskAndContinuedLists() {
    let source = """
    - top
      continued here
      - [x] done
        - deep
      - [ ] todo
    1. first
       - inside
    """
    #expect(parseMarkdown(source) == [
        .bullet("top continued here", ordered: nil),
        .bullet("done", ordered: nil, depth: 1, checked: true),
        .bullet("deep", ordered: nil, depth: 2),
        .bullet("todo", ordered: nil, depth: 1, checked: false),
        .bullet("first", ordered: 1),
        .bullet("inside", ordered: nil, depth: 1),
    ])
}

@Test func markdownQuotesCommentsFencesAndBreaks() {
    let source = """
    <!-- hidden
    still hidden -->
    > one
    > two
    >
    > three
    Title
    =====
    line one\\
    line two
    ~~~js
      let x = 1
    ~~~
    """
    #expect(parseMarkdown(source) == [
        .quote("one two\n\nthree"),
        .heading(level: 1, text: "Title"),
        .paragraph("line one\nline two"),
        .code("  let x = 1", language: "js"),
    ])
}

@Test func eachMarkdownBlockKnowsItsSourceLines() {
    let source = "---\ntitle: Plan\n---\n# Title\n\nOne\ntwo\n\n- a\n  more\n- b\n> q\n> r\n\n| x |\n| - |\n| 1 |\n```sh\nls\n```\nTitle\n---"
    let read = parseMarkdownLines(source)
    #expect(read.blocks.count == read.lines.count)
    #expect(read.lines == [1...3, 4...4, 6...7, 9...10, 11...11, 12...13, 15...17, 18...20, 21...22])
}

@Test func notesQuoteTheirLinesAndCutLongBlocks() {
    let short = FileNote(path: "docs/plan.md", lines: 4...4, quote: ["# Title"], text: "Rename it. ")
    let long = FileNote(path: "README.md", lines: 1...10, quote: (1...10).map { "l\($0)" }, text: "Shorter")
    #expect(notesBody([short, long]) == """
    The human left notes on these files. Address each one:

    docs/plan.md:4
    > # Title
    Rename it.

    README.md:1-10
    > l1
    > l2
    > l3
    > l4
    > ...
    > l8
    > l9
    > l10
    Shorter
    """)
}

@Test func anOrderedListCountsUpHoweverItIsNumbered() {
    let numbers = parseMarkdown("1. a\n1. b\n   - x\n   1. y\n   1. z\n1. c\n\nText\n\n3. d\n3. e").compactMap { block -> Int? in
        if case .bullet(_, let number, _, _) = block { return number }
        return nil
    }
    #expect(numbers == [1, 2, 1, 2, 3, 3, 4])
}
