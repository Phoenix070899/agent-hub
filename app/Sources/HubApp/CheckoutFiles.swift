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
    /// Ignored folders listed on demand; each re-read lists them again, as git does not.
    private var filled: Set<String> = []
    private var stream: FSEventStreamRef?
    /// Folders git ignores, as the watcher names them, so a build writing inside one reads nothing.
    private var ignoredFolders: Set<String> = []
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
        // A changed .gitignore is read here too; learn the ignored folders again.
        ignoredFolders = []
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
                // Parents first, so a folder opened inside another ignored folder is found again.
                for folder in self.filled.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) {
                    self.fill(folder)
                }
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
        fill(folder)
    }

    private func fill(_ folder: String) {
        let url = URL(fileURLWithPath: root).appendingPathComponent(folder)
        guard let found = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
        else {
            filled.remove(folder)
            return
        }
        filled.insert(folder)
        tree.fill(folder, with: found.map {
            ($0.lastPathComponent, (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
        })
    }

    private func watch() {
        // The stream holds this object until `stop()`, so a late event never reaches a freed one.
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<CheckoutFiles>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<CheckoutFiles>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let files = Unmanaged<CheckoutFiles>.fromOpaque(info).takeUnretainedValue()
            let folders = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            DispatchQueue.main.async { MainActor.assumeIsolated { files.changed(folders) } }
        }
        let flags = kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                               FSEventStreamCreateFlags(flags)) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// A change only inside ignored folders, like a build's output, reads nothing while they are hidden.
    private func changed(_ folders: [String]) {
        guard !showIgnored else { return changed() }
        // The watcher names folders by their real path, with a trailing slash.
        let base = URL(fileURLWithPath: root).withUnsafeFileSystemRepresentation { path in
            guard let path, let real = realpath(path, nil) else { return root }
            defer { free(real) }
            return String(cString: real)
        } + "/"
        var unknown: [String] = []
        for folder in folders {
            guard folder.hasPrefix(base), folder.count > base.count else { return changed() }
            let path = String(folder.dropFirst(base.count))
            if path.hasPrefix(".git/") { return changed() }
            if !ignoredFolders.contains(where: { path.hasPrefix($0) }) { unknown.append(path) }
        }
        guard !unknown.isEmpty else { return }
        let root = root
        Task.detached(priority: .utility) {
            let input = unknown.joined(separator: "\0") + "\0"
            // check-ignore exits 1 when nothing is ignored, which reads as no output.
            let output = Git.run(root, ["check-ignore", "--stdin", "-z"], input: input).output ?? ""
            let ignored = Set(output.split(separator: "\0").map(String.init))
            await MainActor.run {
                self.ignoredFolders.formUnion(ignored)
                if unknown.contains(where: { !ignored.contains($0) }) { self.changed() }
            }
        }
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

    /// Stops watching; a read already running still finishes.
    func stop() {
        pending?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

extension CheckoutFiles {
    /// Lines holding `text`, case-insensitively, in tracked and untracked text files; ignored
    /// files too when asked. At most 20 per file and `limit` in all. Cancelling the task stops git.
    nonisolated static func grep(_ root: String, _ text: String, ignored: Bool, limit: Int) async -> [GrepHit] {
        var args = ["grep", "-n", "--null", "-I", "-i", "-F", "--untracked", "--max-count", "20"]
        if ignored { args.append("--no-exclude-standard") }
        args += ["-e", text, "--"]
        let stopper = ProcessStopper()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                // git grep exits 1 when nothing matches, which reads as no output.
                parseGrep(Git.run(root, args, stopper: stopper, lines: limit).output ?? "")
            }.value
        } onCancel: {
            stopper.stop()
        }
    }
}

extension CheckoutFiles {
    /// The branch's own commits, the ones its base branch lacks, newest first; on the base
    /// itself, detached, or with no base found, the latest 50, and `base` is nil.
    nonisolated static func commits(_ root: String, branch: String?) async -> (base: String?, commits: [Commit]) {
        await Task.detached(priority: .userInitiated) {
            let base = baseBranch(root)
            if let base, let branch, branch != base {
                let output = Git.run(root, ["log", commitLogFormat, "-n", "300", "\(base)..HEAD"]).output ?? ""
                return (base, parseCommits(output))
            }
            return (nil, parseCommits(Git.run(root, ["log", commitLogFormat, "-n", "50"]).output ?? ""))
        }.value
    }

    /// The repo's main branch, as a local branch: the remote's default, else main, else master.
    nonisolated private static func baseBranch(_ root: String) -> String? {
        var names: [String] = []
        if let remote = Git.run(root, ["symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD"]).output?
            .trimmingCharacters(in: .whitespacesAndNewlines), remote.hasPrefix("origin/") {
            names.append(String(remote.dropFirst("origin/".count)))
        }
        names += ["main", "master"]
        return names.first { Git.run(root, ["rev-parse", "--verify", "-q", "refs/heads/\($0)"]).output != nil }
    }

    /// The files a commit touched; a merge lists what it brought onto its first parent.
    nonisolated static func files(of commit: String, in root: String) async -> [ChangedFile] {
        await Task.detached(priority: .userInitiated) {
            let output = Git.run(root, ["show", "--format=", "--name-status", "-z", "--diff-merges=first-parent", commit]).output
            return parseNameStatus(output ?? "")
        }.value
    }
}

enum Git {
    /// Runs git in `dir`; nil output when it fails, with what it printed on stderr.
    /// A `stopper` can end it early, which reads as a failure; `input` goes to its stdin. With
    /// `lines`, git is stopped once it has printed that many, which is enough.
    nonisolated static func run(_ dir: String, _ args: [String], input: String? = nil,
                                stopper: ProcessStopper? = nil, lines: Int? = nil) -> (output: String?, error: String?) {
        let process = Process()
        let out = Pipe()
        let err = Pipe()
        let stdin = Pipe()
        if input != nil { process.standardInput = stdin }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir] + args
        // Without this, `git status` takes .git/index.lock to refresh the index, which the watcher
        // sees as a change and reads again: a loop that never settles.
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = env
        process.standardOutput = out
        process.standardError = err
        do {
            if let stopper {
                guard try stopper.launch(process) else { return (nil, "stopped") }
            } else {
                try process.run()
            }
        } catch { return (nil, "\(error)") }
        if let input {
            // Written alongside the reads below, so a long answer cannot block git while it waits.
            DispatchQueue.global().async {
                stdin.fileHandleForWriting.write(Data(input.utf8))
                try? stdin.fileHandleForWriting.close()
            }
        }
        // Read alongside stdout: git blocks once a pipe fills, so one read after the other can
        // leave both sides waiting.
        let problem = PipeContents()
        DispatchQueue.global().async(group: problem.read) {
            problem.data = err.fileHandleForReading.readDataToEndOfFile()
        }
        var data = Data()
        if let lines {
            var count = 0
            while count < lines {
                let chunk = out.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
                count += chunk.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            }
            if count >= lines {
                process.terminate()
                process.waitUntilExit()
                let end = data.split(separator: 0x0A, omittingEmptySubsequences: false).prefix(lines)
                return (end.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n"), nil)
            }
        } else {
            data = out.fileHandleForReading.readDataToEndOfFile()
        }
        process.waitUntilExit()
        problem.read.wait()
        guard process.terminationStatus == 0 else {
            return (nil, String(decoding: problem.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (String(decoding: data, as: UTF8.self), nil)
    }
}

/// What a pipe held, read on another thread.
private final class PipeContents: @unchecked Sendable {
    let read = DispatchGroup()
    var data = Data()
}
