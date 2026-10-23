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
    /// `files` lowercased once, so a search does not lowercase every path per keystroke.
    public private(set) var lowercasedFiles: [String] = []
    /// Paths git ignores; a folder's contents are ignored with it.
    public private(set) var ignored: Set<String> = []

    public init(paths: [String], folders: [String] = [], ignored: [String] = []) {
        self.ignored = Set(ignored.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
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
        lowercasedFiles = files.map { $0.lowercased() }
    }

    /// Whether git ignores `path`, itself or through a folder above it.
    public func isIgnored(_ path: String) -> Bool {
        var path = Substring(path)
        while true {
            if ignored.contains(String(path)) { return true }
            guard let slash = path.lastIndex(of: "/") else { return false }
            path = path[..<slash]
        }
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

/// Paths holding every word of `query`, case-insensitively: those whose name starts with the
/// last word first, then whose name holds it, then the rest; shorter paths first within each.
public func searchFiles(_ query: String, in paths: [String], limit: Int = 50) -> [String] {
    searchFiles(query, in: paths, lowercased: paths.map { $0.lowercased() }, limit: limit)
}

public func searchFiles(_ query: String, in tree: FileTree, limit: Int = 50) -> [String] {
    searchFiles(query, in: tree.files, lowercased: tree.lowercasedFiles, limit: limit)
}

private func searchFiles(_ query: String, in paths: [String], lowercased: [String], limit: Int) -> [String] {
    let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    guard let last = words.last else { return [] }
    var ranked: [(rank: Int, path: String)] = []
    for (path, lower) in zip(paths, lowercased) where words.allSatisfy(lower.contains) {
        let name = lower.lastIndex(of: "/").map { lower[lower.index(after: $0)...] } ?? lower[...]
        ranked.append((name.hasPrefix(last) ? 0 : name.contains(last) ? 1 : 2, path))
    }
    return ranked
        .sorted { ($0.rank, $0.path.count, $0.path) < ($1.rank, $1.path.count, $1.path) }
        .prefix(limit)
        .map(\.path)
}

/// Quick open's best files for `query`, best first, as Quick open scores a file: by its name,
/// else, 10 lower, by "File in <folder>". Ties keep the tree's order. Stops early when cancelled.
public func quickOpenFiles(_ query: String, in tree: FileTree, limit: Int) -> [(score: Int, path: String)] {
    let query = query.lowercased().trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return tree.files.prefix(limit).map { (0, $0) } }
    var best: [(score: Int, path: String)] = []
    for (index, (path, lower)) in zip(tree.files, tree.lowercasedFiles).enumerated() {
        if index % 4096 == 0, Task.isCancelled { return [] }
        let slash = lower.lastIndex(of: "/")
        let name = slash.map { lower[lower.index(after: $0)...] } ?? lower[...]
        let score: Int
        if let byName = quickOpenScore(lowered: query, name) {
            score = byName
        } else {
            let folder = slash.map { "file in " + lower[..<$0] } ?? "file"
            guard let byFolder = quickOpenScore(lowered: query, folder) else { continue }
            score = byFolder - 10
        }
        guard best.count < limit || score > best[best.count - 1].score else { continue }
        best.insert((score, path), at: best.firstIndex { $0.score < score } ?? best.count)
        if best.count > limit { best.removeLast() }
    }
    return best
}

/// One line `git grep` found.
public struct GrepHit: Equatable, Identifiable, Sendable {
    public let path: String
    public let line: Int
    public let text: String

    public var id: String { "\(path):\(line)" }
}

/// `git grep -n --null` output: "path NUL line NUL text" per line.
public func parseGrep(_ output: String) -> [GrepHit] {
    output.split(separator: "\n").compactMap { record in
        let parts = record.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let line = Int(parts[1]) else { return nil }
        return GrepHit(path: String(parts[0]), line: line, text: parts[2].trimmingCharacters(in: .whitespaces))
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

/// A commit as the Commits tab lists it.
public struct Commit: Equatable, Identifiable, Sendable {
    public let hash: String
    public let short: String
    public let subject: String
    public let author: String
    /// When, as git says it relative to now: "3 hours ago".
    public let when: String

    public var id: String { hash }

    public init(hash: String, short: String, subject: String, author: String, when: String) {
        self.hash = hash
        self.short = short
        self.subject = subject
        self.author = author
        self.when = when
    }
}

/// The `git log` format `parseCommits` reads: fields split by 0x1F, commits ended by 0x1E.
public let commitLogFormat = "--format=%H%x1f%h%x1f%s%x1f%an%x1f%ar%x1e"

/// `git log` in `commitLogFormat`, newest first.
public func parseCommits(_ output: String) -> [Commit] {
    output.split(separator: "\u{1E}").compactMap { record in
        let fields = record.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\u{1F}", omittingEmptySubsequences: false)
        guard fields.count == 5, !fields[0].isEmpty else { return nil }
        return Commit(hash: String(fields[0]), short: String(fields[1]), subject: String(fields[2]),
                      author: String(fields[3]), when: String(fields[4]))
    }
}

/// A file a commit touched, with its mark; a rename or copy is listed at its new path.
public struct ChangedFile: Equatable, Sendable {
    public let mark: GitMark
    public let path: String

    public init(mark: GitMark, path: String) {
        self.mark = mark
        self.path = path
    }
}

/// `git show --name-status -z` read into the files a commit touched, in git's order.
public func parseNameStatus(_ output: String) -> [ChangedFile] {
    var files: [ChangedFile] = []
    var fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
    while let status = fields.popFirst() {
        guard let letter = status.first else { continue }
        switch letter {
        case "R", "C":
            // The old path, then the new one.
            _ = fields.popFirst()
            guard let path = fields.popFirst() else { return files }
            files.append(ChangedFile(mark: letter == "R" ? .renamed : .added, path: path))
        default:
            guard let path = fields.popFirst() else { return files }
            let mark: GitMark = letter == "A" ? .added : letter == "D" ? .deleted : .modified
            files.append(ChangedFile(mark: mark, path: path))
        }
    }
    return files
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
    case html
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
    if ["html", "htm"].contains(ext) { return .html }
    return .text
}

/// What Insert into terminal types: Claude Code's `@path` mention, escaped as a dropped path is,
/// with a space after so typing can go on.
public func mentionText(_ relativePath: String) -> String {
    "@" + droppedPaths([relativePath])
}

/// A Markdown document as blocks, enough to render notes, plans, reports, and READMEs: front
/// matter, headings, paragraphs, nested and task lists, quotes, tables, code blocks, and rules.
/// Inline styling stays in each block's text.
public enum MarkdownBlock: Equatable, Sendable {
    /// The YAML between the opening `---` lines, as written.
    case frontMatter(String)
    case heading(level: Int, text: String)
    case paragraph(String)
    /// `depth` 0 is the outermost list; `checked` is set for a task item (`- [x]`).
    case bullet(String, ordered: Int?, depth: Int = 0, checked: Bool? = nil)
    case quote(String)
    case code(String, language: String)
    case table(header: [String], rows: [[String]], alignments: [TableAlignment])
    case rule
}

public enum TableAlignment: Equatable, Sendable {
    case leading, center, trailing
}

public func parseMarkdown(_ source: String) -> [MarkdownBlock] {
    parseMarkdownLines(source).blocks
}

/// The blocks, and for each the 1-based source lines it was read from, so a note on a block can
/// say where it is.
public func parseMarkdownLines(_ source: String) -> (blocks: [MarkdownBlock], lines: [ClosedRange<Int>]) {
    let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var blocks: [MarkdownBlock] = []
    var spans: [ClosedRange<Int>] = []
    /// Adds a block read from lines `from` to `to`, 0-based.
    func add(_ block: MarkdownBlock, _ from: Int, _ to: Int) {
        blocks.append(block)
        spans.append(from + 1...max(from, to) + 1)
    }
    var index = 0
    if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
       let close = lines.indices.dropFirst().first(where: { ["---", "..."].contains(lines[$0].trimmingCharacters(in: .whitespaces)) }) {
        add(.frontMatter(lines[1..<close].joined(separator: "\n")), 0, close)
        index = close + 1
    }

    var paragraph = ""
    var quote: [String] = []
    /// Where the running paragraph and quote started, and the last line either took.
    var paragraphStart = 0
    var quoteStart = 0
    var lastLine = 0
    /// The indents of the lists open around the current item, outermost first.
    var listIndents: [Int] = []
    var afterBlank = false
    func flush() {
        if !paragraph.isEmpty { add(.paragraph(unmark(paragraph)), paragraphStart, lastLine) }
        paragraph = ""
        if !quote.isEmpty {
            add(.quote(quote.joined(separator: " ").replacingOccurrences(of: " \n\n ", with: "\n\n")), quoteStart, lastLine)
        }
        quote = []
    }
    /// Joins a line onto running text: a line ending in a backslash or two spaces breaks there.
    func join(_ text: String, _ raw: String) -> String {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if raw.hasSuffix("  ") && !line.hasSuffix("\\") { line += "\\" }
        guard !text.isEmpty else { return line }
        if text.hasSuffix("\\") { return String(text.dropLast()) + "\n" + line }
        return text + " " + line
    }
    /// A break marked on the last line has nothing to break before.
    func unmark(_ text: String) -> String { text.hasSuffix("\\") ? String(text.dropLast()) : text }

    while index < lines.count {
        let raw = lines[index]
        let line = raw.trimmingCharacters(in: .whitespaces)
        let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        defer { index += 1 }

        if line.isEmpty {
            flush()
            afterBlank = true
            continue
        }
        let blank = afterBlank
        afterBlank = false

        if line.hasPrefix("<!--") {
            flush()
            while index < lines.count, !lines[index].contains("-->") { index += 1 }
            continue
        }
        if line.hasPrefix("```") || line.hasPrefix("~~~") {
            flush()
            let start = index
            let fence = String(line.prefix(3))
            let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var code: [String] = []
            index += 1
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                // Lines keep their own indentation, less the fence's.
                code.append(String(lines[index].dropFirst(min(indent, lines[index].prefix { $0 == " " }.count))))
                index += 1
            }
            add(.code(code.joined(separator: "\n"), language: language), start, min(index, lines.count - 1))
            continue
        }
        if line.contains("|"), index + 1 < lines.count, let alignments = tableAlignments(lines[index + 1]) {
            flush()
            let start = index
            let header = tableCells(line)
            let width = header.count
            var rows: [[String]] = []
            index += 2
            while index < lines.count {
                let row = lines[index].trimmingCharacters(in: .whitespaces)
                guard !row.isEmpty, row.contains("|") else { break }
                let cells = tableCells(row)
                rows.append(Array(cells.prefix(width)) + Array(repeating: "", count: max(0, width - cells.count)))
                index += 1
            }
            index -= 1
            let aligned = Array(alignments.prefix(width)) + Array(repeating: .leading, count: max(0, width - alignments.count))
            add(.table(header: header, rows: rows, alignments: aligned), start, index)
            listIndents = []
            continue
        }
        // "Title" over "=====" or "-----" is a heading.
        if !paragraph.isEmpty, quote.isEmpty, !line.isEmpty, line.allSatisfy({ $0 == "=" }) || line.allSatisfy({ $0 == "-" }) {
            add(.heading(level: line.first == "=" ? 1 : 2, text: paragraph), paragraphStart, index)
            paragraph = ""
            continue
        }
        if let level = headingLevel(line) {
            flush()
            var text = String(line.dropFirst(level + 1))
            while text.hasSuffix("#") { text.removeLast() }
            add(.heading(level: level, text: text.trimmingCharacters(in: .whitespaces)), index, index)
            listIndents = []
            continue
        }
        if isRule(line) {
            flush()
            add(.rule, index, index)
            listIndents = []
            continue
        }
        if line.hasPrefix(">") {
            if !paragraph.isEmpty { flush() }
            var text = line.dropFirst()
            if text.hasPrefix(" ") { text = text.dropFirst() }
            if quote.isEmpty { quoteStart = index }
            lastLine = index
            quote.append(text.isEmpty ? "\n\n" : String(text))
            continue
        }
        if let item = listItem(line) {
            flush()
            while let last = listIndents.last, last > indent { listIndents.removeLast() }
            if listIndents.last.map({ indent > $0 }) ?? true { listIndents.append(indent) }
            var text = item.text
            var checked: Bool?
            for (box, value) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where text.hasPrefix(box) {
                checked = value
                text = String(text.dropFirst(box.count))
            }
            add(.bullet(text, ordered: item.number, depth: listIndents.count - 1, checked: checked), index, index)
            continue
        }
        // A list item's next lines: indented under it, or straight after it.
        if quote.isEmpty, paragraph.isEmpty, case .bullet(let text, let number, let depth, let checked)? = blocks.last,
           !blank || indent >= 2 {
            blocks[blocks.count - 1] = .bullet(join(text, raw), ordered: number, depth: depth, checked: checked)
            spans[spans.count - 1] = spans[spans.count - 1].lowerBound...index + 1
            continue
        }
        if !quote.isEmpty { flush() }
        if indent < 2 || paragraph.isEmpty && blank { listIndents = [] }
        if paragraph.isEmpty { paragraphStart = index }
        lastLine = index
        paragraph = join(paragraph, raw)
    }
    flush()
    // An ordered list counts up from its first number, however its items are numbered ("1." each).
    var counts: [Int: Int] = [:]
    let unmarked = blocks.map { block in
        guard case .bullet(let text, let number, let depth, let checked) = block else {
            counts = [:]
            return block
        }
        counts = counts.filter { $0.key <= depth }
        var shown = number
        if let number {
            shown = counts[depth].map { $0 + 1 } ?? number
            counts[depth] = shown
        } else {
            counts[depth] = nil
        }
        return MarkdownBlock.bullet(unmark(text), ordered: shown, depth: depth, checked: checked)
    }
    return (unmarked, spans)
}

/// A note the human left on lines of a file, for the agent working in that checkout.
public struct FileNote: Equatable, Sendable {
    public var path: String
    /// 1-based, as the file read when the note was written.
    public var lines: ClosedRange<Int>
    /// Those lines' text.
    public var quote: [String]
    public var text: String

    public init(path: String, lines: ClosedRange<Int>, quote: [String], text: String) {
        self.path = path
        self.lines = lines
        self.quote = quote
        self.text = text
    }

    /// `docs/plan.md:12`, or `docs/plan.md:12-14` for a block over several lines.
    public var place: String {
        lines.count == 1 ? "\(path):\(lines.lowerBound)" : "\(path):\(lines.lowerBound)-\(lines.upperBound)"
    }
}

/// Notes as the agent reads them: each under the place and the lines it is about, a long block
/// cut to its first four and last three lines.
public func notesBody(_ notes: [FileNote]) -> String {
    let each = notes.map { note in
        var quote = note.quote
        while quote.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { quote.removeLast() }
        if quote.count > 8 { quote = Array(quote.prefix(4)) + ["..."] + Array(quote.suffix(3)) }
        let quoted = quote.map { "> \($0)" }.joined(separator: "\n")
        return "\(note.place)\n\(quoted)\n\(note.text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
    return "The human left notes on these files. Address each one:\n\n" + each.joined(separator: "\n\n")
}

private func headingLevel(_ line: String) -> Int? {
    let hashes = line.prefix { $0 == "#" }.count
    guard (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") else { return nil }
    return hashes
}

/// "---", "***", "___", or the same with spaces between.
private func isRule(_ line: String) -> Bool {
    let marks = line.filter { $0 != " " }
    guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
    return marks.allSatisfy { $0 == first }
}

/// "- text", "* text", "+ text", "3. text", or "3) text".
private func listItem(_ line: String) -> (text: String, number: Int?)? {
    if let first = line.first, "-*+".contains(first), line.dropFirst().hasPrefix(" ") {
        return (String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces), nil)
    }
    let digits = line.prefix { $0.isNumber }
    guard !digits.isEmpty, digits.count <= 9, let number = Int(digits) else { return nil }
    let rest = line.dropFirst(digits.count)
    guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().hasPrefix(" ") else { return nil }
    return (String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces), number)
}

/// A table's delimiter row, "|:---|---:|", read as each column's alignment; nil for any other line.
private func tableAlignments(_ line: String) -> [TableAlignment]? {
    let cells = tableCells(line.trimmingCharacters(in: .whitespaces))
    guard !cells.isEmpty, line.contains("-") else { return nil }
    var out: [TableAlignment] = []
    for cell in cells {
        guard cell.count >= 1, cell.allSatisfy({ $0 == "-" || $0 == ":" }), cell.contains("-") else { return nil }
        switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
        case (true, true): out.append(.center)
        case (false, true): out.append(.trailing)
        default: out.append(.leading)
        }
    }
    return out
}

/// A table row's cells: split on "|" outside code spans, "\|" kept as a literal bar.
private func tableCells(_ row: String) -> [String] {
    var line = Substring(row)
    if line.hasPrefix("|") { line = line.dropFirst() }
    if line.hasSuffix("|") && !line.hasSuffix("\\|") { line = line.dropLast() }
    var cells: [String] = []
    var cell = ""
    var inCode = false
    var escaped = false
    for char in line {
        if escaped {
            cell.append(char == "|" ? "|" : "\\\(char)")
            escaped = false
        } else if char == "\\" {
            escaped = true
        } else if char == "`" {
            inCode.toggle()
            cell.append(char)
        } else if char == "|" && !inCode {
            cells.append(cell.trimmingCharacters(in: .whitespaces))
            cell = ""
        } else {
            cell.append(char)
        }
    }
    if escaped { cell.append("\\") }
    cells.append(cell.trimmingCharacters(in: .whitespaces))
    return cells
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
