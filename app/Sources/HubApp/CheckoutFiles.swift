import CoreServices
import Foundation
import HubCore

/// The files of one checkout (the repo's, or an agent's or Worker's worktree) as the Files column
/// shows them: what git lists, each file's git status, and the branch. It watches the folder and
/// reads it again within half a second of any change, so an agent's edits show as they happen.
@MainActor
final class CheckoutFiles: ObservableObject {
    let root: String
    @Published private(set) var tree = FileTree(paths: [])
    @Published private(set) var marks: [String: GitMark] = [:]
    @Published private(set) var branch: String?
    @Published private(set) var loaded = false
    @Published private(set) var problem: String?
    /// Bumped on every change seen, so an open preview reads its file again.
    @Published private(set) var generation = 0

    private var showIgnored = false
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var reading = false
    private var readAgain = false

    init(root: String) {
        self.root = root
    }

    /// Starts reading and watching; showing ignored files reads them too.
    func start(showIgnored: Bool) {
        if self.showIgnored != showIgnored || !loaded {
            self.showIgnored = showIgnored
            reload()
        }
        if stream == nil { watch() }
    }

    func reload() {
        guard !reading else {
            readAgain = true
            return
        }
        reading = true
        let root = root
        let ignored = showIgnored
        Task.detached(priority: .userInitiated) {
            let listed = Git.run(root, ["ls-files", "--cached", "--others", "--exclude-standard", "-z"])
            let status = Git.run(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"])
            let branch = Git.run(root, ["branch", "--show-current"])
            var paths = (listed.output ?? "").split(separator: "\0").map(String.init)
            var folders: [String] = []
            var ignoredPaths: [String] = []
            if ignored {
                let extra = (Git.run(root, ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"]).output ?? "")
                    .split(separator: "\0").map(String.init)
                folders = extra.filter { $0.hasSuffix("/") }
                paths += extra.filter { !$0.hasSuffix("/") }
                ignoredPaths = extra
            }
            let tree = FileTree(paths: paths, folders: folders, ignored: ignoredPaths)
            let marks = parseGitStatus(status.output ?? "")
            let problem = listed.output == nil ? (listed.error ?? "git could not list \(root)") : nil
            let name = branch.output?.trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                self.tree = tree
                self.marks = marks
                self.branch = (name?.isEmpty ?? true) ? nil : name
                self.problem = problem
                self.loaded = true
                self.reading = false
                if self.readAgain {
                    self.readAgain = false
                    self.reload()
                }
            }
        }
    }

    /// Lists an ignored folder's contents the first time it is opened; git lists it as one entry.
    func fillIfNeeded(_ folder: String) {
        guard tree.children[folder] == nil else { return }
        let url = URL(fileURLWithPath: root).appendingPathComponent(folder)
        let found = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        tree.fill(folder, with: found.map {
            ($0.lastPathComponent, (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
        })
    }

    private func watch() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let files = Unmanaged<CheckoutFiles>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { files.changed() } }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Many events arrive at once while an agent writes; only the last one reads the folder.
    private func changed() {
        pending?.cancel()
        let read = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.reload()
        }
        pending = read
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: read)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

extension CheckoutFiles {
    /// Lines holding `text`, case-insensitively, in tracked and untracked text files; ignored
    /// files too when they are shown. At most 20 per file.
    nonisolated static func grep(_ root: String, _ text: String, ignored: Bool) -> [GrepHit] {
        var args = ["grep", "-n", "--null", "-I", "-i", "-F", "--untracked", "--max-count", "20"]
        if ignored { args.append("--no-exclude-standard") }
        args += ["-e", text, "--"]
        // git grep exits 1 when nothing matches, which reads as no output.
        return parseGrep(Git.run(root, args).output ?? "")
    }
}

enum Git {
    /// Runs git in `dir`; nil output when it fails, with what it printed on stderr.
    nonisolated static func run(_ dir: String, _ args: [String]) -> (output: String?, error: String?) {
        let process = Process()
        let out = Pipe()
        let err = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir] + args
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (nil, "\(error)") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let problem = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return (nil, String(decoding: problem, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (String(decoding: data, as: UTF8.self), nil)
    }
}
