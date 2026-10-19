import Foundation

/// One row of the Files column: a folder or a file, at a path relative to the checkout.
public struct FileEntry: Equatable, Identifiable, Sendable {
    public let path: String
    public let isFolder: Bool
    /// How deep it sits: 0 at the checkout's top.
    public let depth: Int

    public var id: String { path }
    public var name: String { String(path.split(separator: "/").last ?? "") }

    public init(path: String, isFolder: Bool, depth: Int) {
        self.path = path
        self.isFolder = isFolder
        self.depth = depth
    }
}

/// The folders and files under each folder ("" is the top), from a flat list of file paths
/// such as `git ls-files` prints. Folders come before files; each group is in Finder order.
public struct FileTree: Equatable, Sendable {
    public private(set) var children: [String: [FileEntry]] = [:]
    public private(set) var files: [String] = []

    public init(paths: [String], folders: [String] = []) {
        var seen = Set<String>()
        var entries: [String: [FileEntry]] = [:]
        func add(_ path: String, folder: Bool) {
            guard !path.isEmpty, seen.insert(path).inserted else { return }
            let parts = path.split(separator: "/")
            let parent = parts.dropLast().joined(separator: "/")
            if !parent.isEmpty { add(parent, folder: true) }
            entries[parent, default: []].append(FileEntry(path: path, isFolder: folder, depth: parts.count - 1))
        }
        for folder in folders { add(folder.hasSuffix("/") ? String(folder.dropLast()) : folder, folder: true) }
        for path in paths where !path.hasSuffix("/") { add(path, folder: false) }
        for (key, list) in entries {
            entries[key] = list.sorted { a, b in
                if a.isFolder != b.isFolder { return a.isFolder }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        children = entries
        files = paths.filter { !$0.hasSuffix("/") }.sorted()
    }

    /// The rows on screen: each open folder's contents under it, depth first.
    public func rows(open: Set<String>) -> [FileEntry] {
        var out: [FileEntry] = []
        func walk(_ folder: String) {
            for entry in children[folder] ?? [] {
                out.append(entry)
                if entry.isFolder && open.contains(entry.path) { walk(entry.path) }
            }
        }
        walk("")
        return out
    }

    /// Adds a folder's contents found later, like an ignored folder listed only when opened.
    public mutating func fill(_ folder: String, with entries: [(name: String, isFolder: Bool)]) {
        let depth = folder.isEmpty ? 0 : folder.split(separator: "/").count
        let list = entries.map {
            FileEntry(path: folder.isEmpty ? $0.name : "\(folder)/\($0.name)", isFolder: $0.isFolder, depth: depth)
        }
        children[folder] = list.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// A file's state in `git status`, as the Files column marks it.
public enum GitMark: String, Equatable, Sendable {
    case modified = "M"
    case added = "A"
    case untracked = "?"
    case deleted = "D"
    case renamed = "R"
}

/// `git status --porcelain=v1 -z` read into a mark per path. A rename is marked at its new path.
public func parseGitStatus(_ output: String) -> [String: GitMark] {
    var marks: [String: GitMark] = [:]
    var records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
    while let record = records.popFirst() {
        guard record.count > 3 else { continue }
        let code = Array(record.prefix(2))
        let path = String(record.dropFirst(3))
        let mark: GitMark
        switch (code[0], code[1]) {
        case ("?", "?"): mark = .untracked
        case ("R", _), (_, "R"): mark = .renamed
            _ = records.popFirst() // The old path follows a rename.
        case ("A", _): mark = .added
        case ("D", _), (_, "D"): mark = .deleted
        default: mark = .modified
        }
        marks[path] = mark
    }
    return marks
}

/// Whether anything under `folder` has a mark, for the dot on a closed folder.
public func folderHasChanges(_ folder: String, in marks: [String: GitMark]) -> Bool {
    let prefix = folder + "/"
    return marks.keys.contains { $0.hasPrefix(prefix) }
}

/// What a file is, for how the preview shows it.
public enum FileKind: Equatable, Sendable {
    case text
    case markdown
    case image
    case pdf
    case binary
}

public func fileKind(path: String, head: Data) -> FileKind {
    let ext = (path as NSString).pathExtension.lowercased()
    if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "ico", "svg"].contains(ext) { return .image }
    if ext == "pdf" { return .pdf }
    // A NUL in the first 8 KB means a binary file, as git decides.
    if head.prefix(8192).contains(0) { return .binary }
    if ["md", "markdown", "mdx"].contains(ext) { return .markdown }
    return .text
}

/// What Insert into terminal types: Claude Code's `@path` mention, escaped as a dropped path is,
/// with a space after so typing can go on.
public func mentionText(_ relativePath: String) -> String {
    "@" + droppedPaths([relativePath])
}

/// A Markdown document as blocks, enough to render notes, reports, and READMEs: headings,
/// paragraphs, lists, quotes, code blocks, and rules. Inline styling stays in each block's text.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String, ordered: Int?)
    case quote(String)
    case code(String, language: String)
    case rule
}

public func parseMarkdown(_ source: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []
    var code: [String]?
    var language = ""
    func flush() {
        if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
        paragraph = []
    }
    for raw in source.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if code != nil {
            if line.hasPrefix("```") {
                blocks.append(.code(code!.joined(separator: "\n"), language: language))
                code = nil
            } else {
                code!.append(raw)
            }
            continue
        }
        if line.hasPrefix("```") {
            flush()
            code = []
            language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        } else if line.isEmpty {
            flush()
        } else if let level = headingLevel(line) {
            flush()
            blocks.append(.heading(level: level, text: String(line.dropFirst(level + 1))))
        } else if line == "---" || line == "***" || line == "___" {
            flush()
            blocks.append(.rule)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            flush()
            blocks.append(.bullet(String(line.dropFirst(2)), ordered: nil))
        } else if let dot = line.firstIndex(of: "."), let number = Int(line[..<dot]),
                  line[line.index(after: dot)...].hasPrefix(" ") {
            flush()
            blocks.append(.bullet(String(line[line.index(dot, offsetBy: 2)...]), ordered: number))
        } else if line.hasPrefix(">") {
            flush()
            blocks.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
        } else {
            paragraph.append(line)
        }
    }
    if let code { blocks.append(.code(code.joined(separator: "\n"), language: language)) }
    flush()
    return blocks
}

private func headingLevel(_ line: String) -> Int? {
    let hashes = line.prefix { $0 == "#" }.count
    guard (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") else { return nil }
    return hashes
}

/// Lines that differ between two versions of a file, by position, for the brief highlight when
/// an agent changes the file on screen.
public func changedLines(old: [String], new: [String]) -> Set<Int> {
    var changed = Set<Int>()
    for index in new.indices where index >= old.count || old[index] != new[index] {
        changed.insert(index)
    }
    return changed
}
