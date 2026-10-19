import Foundation

/// One file in a unified diff, as `git diff` prints it.
public struct DiffFile: Equatable, Sendable {
    public enum Change: Equatable, Sendable { case added, deleted, modified }

    public var path: String
    public var change: Change = .modified
    public var lines: [DiffLine] = []
    /// "Binary files differ": no lines to show.
    public var binary = false

    public var additions: Int { lines.filter { $0.kind == .added }.count }
    public var deletions: Int { lines.filter { $0.kind == .removed }.count }
}

/// A line of a diff hunk, with its numbers in the old and new file.
public struct DiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case hunk, context, added, removed, note }

    public var kind: Kind
    public var text: String
    public var old: Int?
    public var new: Int?
}

/// Splits `git diff` output into files and numbered lines.
public func parseDiff(_ text: String) -> [DiffFile] {
    var files: [DiffFile] = []
    var old = 0
    var new = 0
    var inHunk = false

    func headerPath(_ line: Substring) -> String {
        // `diff --git a/x b/x`: the b side, which a rename or new file names.
        guard let range = line.range(of: " b/", options: .backwards) else { return String(line) }
        return String(line[range.upperBound...])
    }

    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("diff --git ") {
            files.append(DiffFile(path: headerPath(line)))
            inHunk = false
            continue
        }
        guard !files.isEmpty else { continue }
        let last = files.count - 1
        if line.hasPrefix("@@") {
            let numbers = hunkStarts(line)
            old = numbers.old
            new = numbers.new
            inHunk = true
            files[last].lines.append(DiffLine(kind: .hunk, text: String(line)))
            continue
        }
        if !inHunk {
            if line.hasPrefix("new file mode") || line == "--- /dev/null" { files[last].change = .added }
            if line.hasPrefix("deleted file mode") || line == "+++ /dev/null" { files[last].change = .deleted }
            if line.hasPrefix("+++ b/") { files[last].path = String(line.dropFirst(6)) }
            if line.hasPrefix("Binary files") { files[last].binary = true }
            continue
        }
        switch line.first {
        case "+":
            files[last].lines.append(DiffLine(kind: .added, text: String(line.dropFirst()), new: new))
            new += 1
        case "-":
            files[last].lines.append(DiffLine(kind: .removed, text: String(line.dropFirst()), old: old))
            old += 1
        case " ":
            files[last].lines.append(DiffLine(kind: .context, text: String(line.dropFirst()), old: old, new: new))
            old += 1
            new += 1
        case "\\":
            files[last].lines.append(DiffLine(kind: .note, text: String(line.dropFirst(2))))
        default:
            // The blank line that ends the output.
            continue
        }
    }
    return files
}

/// The first old and new line numbers of `@@ -12,7 +12,8 @@`.
private func hunkStarts(_ line: Substring) -> (old: Int, new: Int) {
    func start(_ marker: Character) -> Int {
        guard let word = line.split(separator: " ").first(where: { $0.first == marker }) else { return 1 }
        return Int(word.dropFirst().split(separator: ",").first ?? "") ?? 1
    }
    return (start("-"), start("+"))
}

/// A comment the human left on one line of a Worker's diff.
public struct ReviewComment: Equatable, Sendable {
    public var path: String
    public var line: DiffLine
    public var text: String

    public init(path: String, line: DiffLine, text: String) {
        self.path = path
        self.line = line
        self.text = text
    }

    /// `README.md:12`, or `README.md:12 (removed)` for a line the change takes out.
    public var place: String {
        line.kind == .removed ? "\(path):\(line.old ?? 0) (removed)" : "\(path):\(line.new ?? 0)"
    }
}

/// A review as the Worker or Orchestrator reads it: each comment under the line it is about.
public func reviewBody(_ comments: [ReviewComment]) -> String {
    comments.map { comment in
        "\(comment.place)\n> \(comment.line.text.trimmingCharacters(in: .whitespaces))\n\(comment.text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }.joined(separator: "\n\n")
}
