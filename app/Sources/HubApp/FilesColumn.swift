import AppKit
import HubCore
import SwiftUI

/// The Files column (⇧⌘E): the selected agent's or Worker's checkout as a tree, with git marks.
/// A click previews a file; Return types `@path` into the terminal.
struct FilesColumn: View {
    @EnvironmentObject private var model: AppModel
    let root: String

    var body: some View {
        FilesTree(files: model.checkoutFiles(root), root: root)
            .id(root)
    }
}

private struct FilesTree: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var files: CheckoutFiles
    let root: String
    @FocusState private var focused: Bool
    @StateObject private var typed = TypeSelect()
    /// The last ⇧⌘E this tree took the keyboard for, so a relaunch or reselect does not steal it.
    @StateObject private var handledFocus = FocusRequest()
    @StateObject private var search = Draft()

    private var rows: [FileEntry] { files.tree.rows(open: model.openFolders(root)) }
    private var cursor: String? { model.fileCursor[root] }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            header
            FilesSearchField(query: $search.text)
            if !search.text.trimmingCharacters(in: .whitespaces).isEmpty {
                FileSearchResults(files: files, root: root, query: search.text)
            } else if let problem = files.problem {
                Text(problem)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ledger.failInk)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if files.loaded && rows.isEmpty {
                Text("No files here yet.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ledger.ink3)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { entry in
                                FileRow(entry: entry, root: root, mark: mark(entry), ignored: files.tree.isIgnored(entry.path),
                                        open: model.openFolders(root).contains(entry.path),
                                        picked: cursor == entry.path) {
                                    focused = true
                                    activate(entry)
                                }
                                .id(entry.path)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .focusable()
                    .focused($focused)
                    .focusEffectDisabled()
                    .onKeyPress(phases: .down) { press in key(press, rows: rows) }
                    // Opening the column hands it the keyboard; the terminal takes it back after.
                    .onAppear {
                        if model.filesFocusRequest != handledFocus.value {
                            handledFocus.value = model.filesFocusRequest
                            DispatchQueue.main.async { focused = true }
                        }
                    }
                    .onChange(of: model.filesFocusRequest) {
                        handledFocus.value = model.filesFocusRequest
                        focused = true
                    }
                    // Selecting an agent or Worker in the ledger hands the keyboard to its terminal.
                    .onChange(of: model.terminalFocusRequest) { focused = false }
                    .onChange(of: focused) { model.treeFocused = focused }
                    .onDisappear { model.treeFocused = false }
                    .onChange(of: cursor) {
                        if let cursor { proxy.scrollTo(cursor) }
                    }
                }
            }
            Text("Space previews. Return types its @path.")
                .font(.system(size: 12))
                .foregroundStyle(Ledger.ink3)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Ledger.band)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Files").fontWeight(.semibold)
            if let branch = files.branch {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10.5))
                    Text(branch).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                }
                .foregroundStyle(Ledger.ink2)
                .help(root)
            }
            Spacer(minLength: 4)
            Button { model.showIgnoredFiles.toggle() } label: {
                Image(systemName: model.showIgnoredFiles ? "eye.fill" : "eye")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.showIgnoredFiles ? Ledger.ink : Ledger.ink2)
            .help(model.showIgnoredFiles ? "Hide ignored files" : "Show ignored files")
            .accessibilityLabel(model.showIgnoredFiles ? "Hide ignored files" : "Show ignored files")
            Button { model.toggleFiles() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ledger.ink2)
            .help("Hide Files (⇧⌘E)")
            .accessibilityLabel("Hide Files")
        }
        .font(.system(size: 13))
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Ledger.band)
    }

    private func mark(_ entry: FileEntry) -> RowMark? {
        if entry.isFolder { return folderHasChanges(entry.path, in: files.marks) ? .folder : nil }
        return files.marks[entry.path].map(RowMark.file)
    }

    /// A click: a folder opens or closes; a file is previewed.
    private func activate(_ entry: FileEntry) {
        model.fileCursor[root] = entry.path
        if entry.isFolder {
            toggle(entry)
        } else {
            model.preview = FileRef(root: root, path: entry.path)
        }
    }

    private func toggle(_ entry: FileEntry) {
        let open = model.openFolders(root).contains(entry.path)
        if !open { files.fillIfNeeded(entry.path) }
        withAnimation(.easeOut(duration: 0.12)) { model.setFolder(entry.path, open: !open, in: root) }
    }

    private func key(_ press: KeyPress, rows: [FileEntry]) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        let index = cursor.flatMap { c in rows.firstIndex { $0.path == c } }
        let entry = index.map { rows[$0] }
        switch press.key {
        case .downArrow, .upArrow:
            guard !rows.isEmpty else { return .handled }
            let step = press.key == .downArrow ? 1 : -1
            let next = index.map { max(0, min(rows.count - 1, $0 + step)) } ?? 0
            model.fileCursor[root] = rows[next].path
        case .rightArrow:
            guard let entry, entry.isFolder else { return .handled }
            if model.openFolders(root).contains(entry.path) {
                if let index, index + 1 < rows.count { model.fileCursor[root] = rows[index + 1].path }
            } else {
                toggle(entry)
            }
        case .leftArrow:
            guard let entry else { return .handled }
            if entry.isFolder && model.openFolders(root).contains(entry.path) {
                toggle(entry)
            } else if let slash = entry.path.lastIndex(of: "/") {
                model.fileCursor[root] = String(entry.path[..<slash])
            }
        case .space:
            guard let entry else { return .handled }
            if entry.isFolder { toggle(entry) } else { model.preview = FileRef(root: root, path: entry.path) }
        case .return:
            guard let entry else { return .handled }
            if entry.isFolder {
                toggle(entry)
            } else if model.terminalTypeable {
                model.insertMention(FileRef(root: root, path: entry.path))
            } else {
                model.preview = FileRef(root: root, path: entry.path)
            }
        case .escape:
            guard model.preview != nil else { return .ignored }
            model.preview = nil
        case .tab:
            // Tab hands the keyboard to the previewed file, to leave notes on it.
            guard model.preview != nil, !press.modifiers.contains(.shift) else { return .ignored }
            model.previewFocusRequest += 1
        default:
            // Typing a name jumps to it, as in Finder.
            let text = press.characters.lowercased()
            guard text.count == 1, let char = text.first, char.isLetter || char.isNumber || char == "." || char == "_" || char == "-"
            else { return .ignored }
            let prefix = typed.add(char)
            let start = (index ?? -1) + (prefix.count == 1 ? 1 : 0)
            let order = Array(rows[max(0, min(start, rows.count))...]) + Array(rows[..<max(0, min(start, rows.count))])
            if let hit = order.first(where: { $0.name.lowercased().hasPrefix(prefix) }) {
                model.fileCursor[root] = hit.path
            }
        }
        return .handled
    }
}

final class FocusRequest: ObservableObject {
    var value = 0
}

/// Letters typed in a row, forgotten after a second's pause.
final class TypeSelect: ObservableObject {
    private var text = ""
    private var last = Date.distantPast

    func add(_ char: Character) -> String {
        if Date().timeIntervalSince(last) > 1 { text = "" }
        last = Date()
        text.append(char)
        return text
    }
}

enum RowMark: Equatable {
    case file(GitMark)
    /// Something inside changed.
    case folder
}

private struct FileRow: View {
    @EnvironmentObject private var model: AppModel
    let entry: FileEntry
    let root: String
    let mark: RowMark?
    /// Covered by .gitignore: drawn dim.
    let ignored: Bool
    let open: Bool
    let picked: Bool
    let click: () -> Void
    @StateObject private var hover = Flag()

    private var file: FileRef { FileRef(root: root, path: entry.path) }

    var body: some View {
        HStack(spacing: 6) {
            if entry.isFolder {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Ledger.ink3)
                    .frame(width: 10)
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Ledger.ink3)
            } else {
                Spacer().frame(width: 10)
                Image(systemName: "doc")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Ledger.ink3)
            }
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(nameColor)
            Spacer(minLength: 6)
            switch mark {
            case .file(let git)?:
                Text(git.rawValue)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color(git))
                    .accessibilityLabel(label(git))
            case .folder?:
                Circle().fill(Ledger.changed).frame(width: 6, height: 6)
                    .accessibilityLabel("Has changes")
            case nil:
                EmptyView()
            }
        }
        .font(.system(size: 13))
        .padding(.leading, 10 + CGFloat(entry.depth) * 14)
        .padding(.trailing, 12)
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(picked ? Ledger.selected : hover.on ? Ledger.wash : Color.clear)
        .overlay(alignment: .leading) {
            if picked { Rectangle().fill(Ledger.run).frame(width: 3) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: click)
        .onHover { hover.on = $0 }
        .onDrag { NSItemProvider(object: file.url as NSURL) }
        .contextMenu {
            if !entry.isFolder {
                Button("Preview") { model.preview = file }
                Button("Insert into Terminal") { model.insertMention(file) }
                    .disabled(!model.terminalTypeable)
                Button("Open") { model.openInEditor(file) }
                Divider()
            }
            Button("Reveal in Finder") { model.revealInFinder(file) }
            Button("Copy Path") { model.copyPath(file) }
        }
        .help(entry.path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
    }

    private var nameColor: Color {
        switch mark {
        case .file(.modified)?, .file(.renamed)?: Ledger.changed
        case .file(.added)?, .file(.untracked)?: Ledger.done
        case .file(.deleted)?: Ledger.fail
        default: ignored ? Ledger.ink3 : Ledger.ink
        }
    }

    private func color(_ mark: GitMark) -> Color {
        switch mark {
        case .modified, .renamed: Ledger.changed
        case .added, .untracked: Ledger.done
        case .deleted: Ledger.fail
        }
    }

    private func label(_ mark: GitMark) -> String {
        switch mark {
        case .modified: "Modified"
        case .added: "Added"
        case .untracked: "New"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        }
    }
}

/// Filters the Files column: file names, and text inside files.
private struct FilesSearchField: View {
    @Binding var query: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11.5)).foregroundStyle(Ledger.ink3)
            TextField("Search files and text", text: $query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onKeyPress(.escape) {
                    guard !query.isEmpty else { return .ignored }
                    query = ""
                    return .handled
                }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Ledger.ink3)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Ledger.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// What a search found: files whose path matches, then lines holding the text, by file.
/// A file opens its preview; a line opens it at that line.
private struct FileSearchResults: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var files: CheckoutFiles
    let root: String
    let query: String
    @StateObject private var found = SearchHits()

    private static let hitLimit = 300

    var body: some View {
        let named = found.named
        let hits = found.hits
        let byFile = Dictionary(grouping: hits, by: \.path)
        let order = hits.map(\.path).reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                section("Files", count: named.count)
                if named.isEmpty { note("No file names match.") }
                ForEach(named, id: \.self) { path in
                    ResultFile(path: path, ignored: files.tree.isIgnored(path)) {
                        model.preview = FileRef(root: root, path: path)
                    }
                }
                section("Text", count: hits.count) {
                    Button { model.searchIgnoredFiles.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: model.searchIgnoredFiles ? "checkmark.square.fill" : "square")
                            Text("Ignored files")
                        }
                        .font(.system(size: 11.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.searchIgnoredFiles ? Ledger.ink : Ledger.ink3)
                    .help(model.searchIgnoredFiles ? "Stop searching text in ignored files" : "Search text in ignored files too (slower)")
                    .accessibilityLabel("Search ignored files")
                    .accessibilityValue(model.searchIgnoredFiles ? "On" : "Off")
                }
                if query.trimmingCharacters(in: .whitespaces).count < 2 {
                    note("Type 2 or more characters to search inside files.")
                } else if hits.isEmpty {
                    note(found.searching ? "Searching…" : "No lines match.")
                }
                ForEach(order, id: \.self) { path in
                    ResultFile(path: path, ignored: files.tree.isIgnored(path)) {
                        model.preview = FileRef(root: root, path: path)
                    }
                    ForEach(byFile[path] ?? []) { hit in
                        ResultLine(hit: hit) { model.showPreview(FileRef(root: root, path: path), line: hit.line) }
                    }
                }
                if hits.count >= Self.hitLimit {
                    note("Showing the first \(Self.hitLimit) lines. Narrow the search to see more.")
                }
            }
            .padding(.bottom, 8)
        }
        // File names match on every keystroke, away from the main thread.
        .task(id: "\(query)|\(files.generation)") {
            let tree = files.tree
            let query = query
            let named = await Task.detached(priority: .userInitiated) { searchFiles(query, in: tree) }.value
            guard !Task.isCancelled else { return }
            found.named = named
        }
        // Waits for a pause in typing, and searches again when the checkout changes.
        .task(id: "\(query)|\(files.generation)|\(model.searchIgnoredFiles)") {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard text.count >= 2 else {
                found.hits = []
                return
            }
            found.searching = true
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let root = root
            let ignored = model.searchIgnoredFiles
            let lines = await CheckoutFiles.grep(root, text, ignored: ignored, limit: Self.hitLimit)
            guard !Task.isCancelled else { return }
            found.hits = lines
            found.searching = false
        }
    }

    private func section(_ title: String, count: Int, @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 6) {
            Text(title).fontWeight(.semibold)
            Text("\(count)").foregroundStyle(Ledger.ink3).monospacedDigit()
            Spacer(minLength: 8)
            trailing()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Ledger.ink3)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
    }
}

final class SearchHits: ObservableObject {
    @Published var named: [String] = []
    @Published var hits: [GrepHit] = []
    @Published var searching = false
}

private struct ResultFile: View {
    let path: String
    let ignored: Bool
    let click: () -> Void
    @StateObject private var hover = Flag()

    var body: some View {
        let name = (path as NSString).lastPathComponent
        let folder = (path as NSString).deletingLastPathComponent
        HStack(spacing: 6) {
            Image(systemName: "doc").font(.system(size: 11.5)).foregroundStyle(Ledger.ink3)
            Text(name).foregroundStyle(ignored ? Ledger.ink3 : Ledger.ink).lineLimit(1)
            Text(folder)
                .font(.system(size: 12))
                .foregroundStyle(Ledger.ink3)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .frame(height: 24)
        .background(hover.on ? Ledger.wash : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: click)
        .onHover { hover.on = $0 }
        .help(path)
    }
}

private struct ResultLine: View {
    let hit: GrepHit
    let click: () -> Void
    @StateObject private var hover = Flag()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(hit.line)")
                .foregroundStyle(Ledger.ink3)
                .frame(minWidth: 28, alignment: .trailing)
            Text(hit.text).foregroundStyle(Ledger.ink2).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .frame(height: 22)
        .background(hover.on ? Ledger.wash : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: click)
        .onHover { hover.on = $0 }
        .help("\(hit.path):\(hit.line)")
    }
}
