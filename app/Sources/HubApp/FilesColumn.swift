import AppKit
import HubCore
import SwiftUI

/// The Files column (⇧⌘E): the selected agent's or Worker's checkout as a tree with git marks,
/// its changes as git status lists them, or its branch's commits. A click previews a file;
/// Return types `@path` into the terminal.
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
    /// Kept while another tab shows, so coming back does not start empty.
    @StateObject private var commits = CommitsState()

    private var rows: [FileEntry] { files.tree.rows(open: model.openFolders(root)) }
    private var cursor: String? { model.fileCursor[root] }

    var body: some View {
        VStack(spacing: 0) {
            header
            FilesTabBar(changes: files.marks.count, commits: commits.loaded ? commits.commits.count : nil)
            switch model.filesTab {
            case .files: tree
            case .changes: ChangedFilesList(files: files, root: root)
            case .commits: CommitsList(files: files, root: root, state: commits)
            }
            Text(model.filesTab.hint)
                .font(.system(size: 12))
                .foregroundStyle(Ledger.ink3)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Ledger.band)
        }
    }

    @ViewBuilder
    private var tree: some View {
        let rows = rows
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
                .onChange(of: focused) { model.filesFocused(.files, focused) }
                .onDisappear { model.filesFocused(.files, false) }
                .onChange(of: cursor) {
                    if let cursor { proxy.scrollTo(cursor) }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let branch = files.branch {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10.5))
                    Text(branch).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                }
                .foregroundStyle(Ledger.ink2)
                .help(root)
            }
            Spacer(minLength: 4)
            if model.filesTab == .files {
                Button { model.showIgnoredFiles.toggle() } label: {
                    Image(systemName: model.showIgnoredFiles ? "eye.fill" : "eye")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.showIgnoredFiles ? Ledger.ink : Ledger.ink2)
                .help(model.showIgnoredFiles ? "Hide ignored files" : "Show ignored files")
                .accessibilityLabel(model.showIgnoredFiles ? "Hide ignored files" : "Show ignored files")
            }
            Button { model.hideFiles() } label: {
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

    private func color(_ mark: GitMark) -> Color { gitMarkColor(mark) }

    private func label(_ mark: GitMark) -> String { gitMarkLabel(mark) }
}

private func gitMarkColor(_ mark: GitMark) -> Color {
    switch mark {
    case .modified, .renamed: Ledger.changed
    case .added, .untracked: Ledger.done
    case .deleted: Ledger.fail
    }
}

private func gitMarkLabel(_ mark: GitMark) -> String {
    switch mark {
    case .modified: "Modified"
    case .added: "Added"
    case .untracked: "New"
    case .deleted: "Deleted"
    case .renamed: "Renamed"
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

/// The Files column's views, in the order of its tabs.
enum FilesTab: String, CaseIterable, Identifiable {
    case files, changes, commits

    var id: Self { self }

    var title: String {
        switch self {
        case .files: "Files"
        case .changes: "Changes"
        case .commits: "Commits"
        }
    }

    /// The line at the bottom of the column.
    var hint: String {
        switch self {
        case .files, .changes: "Space previews. Return types its @path."
        case .commits: "Space opens a commit or previews a file."
        }
    }
}

/// Files | Changes | Commits, under the column's header; Changes and Commits show their counts.
private struct FilesTabBar: View {
    @EnvironmentObject private var model: AppModel
    let changes: Int
    /// Nil until the commits are read.
    let commits: Int?

    var body: some View {
        HStack(spacing: 16) {
            ForEach(FilesTab.allCases) { tab in
                let picked = model.filesTab == tab
                Button { model.filesTab = tab } label: {
                    HStack(spacing: 5) {
                        Text(tab.title)
                        if let count = count(tab) {
                            Text("\(count)").foregroundStyle(Ledger.ink3).monospacedDigit()
                        }
                    }
                    .font(.system(size: 12.5, weight: picked ? .semibold : .regular))
                    .foregroundStyle(picked ? Ledger.ink : Ledger.ink2)
                    .padding(.bottom, 7)
                    .overlay(alignment: .bottom) {
                        if picked { Rectangle().fill(Ledger.ink).frame(height: 2) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .background(Ledger.band)
        .overlay(alignment: .bottom) { Rectangle().fill(Ledger.rule).frame(height: 1) }
    }

    private func count(_ tab: FilesTab) -> Int? {
        switch tab {
        case .files: nil
        case .changes: changes > 0 ? changes : nil
        case .commits: commits.flatMap { $0 > 0 ? $0 : nil }
        }
    }
}

/// The keyboard rules each list in the column shares with the tree: ⇧⌘E hands it the keyboard,
/// selecting an agent hands it to the terminal, and the preview knows while the list holds it.
private struct FilesListFocus: ViewModifier {
    @EnvironmentObject private var model: AppModel
    let tab: FilesTab
    var focused: FocusState<Bool>.Binding
    @StateObject private var handled = FocusRequest()

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused(focused)
            .focusEffectDisabled()
            .onAppear {
                if model.filesFocusRequest != handled.value {
                    handled.value = model.filesFocusRequest
                    DispatchQueue.main.async { focused.wrappedValue = true }
                }
            }
            .onChange(of: model.filesFocusRequest) {
                handled.value = model.filesFocusRequest
                focused.wrappedValue = true
            }
            .onChange(of: model.terminalFocusRequest) { focused.wrappedValue = false }
            .onChange(of: focused.wrappedValue) { model.filesFocused(tab, focused.wrappedValue) }
            .onDisappear { model.filesFocused(tab, false) }
    }
}

/// The row the keyboard is on in a list of the column.
final class Pick: ObservableObject {
    @Published var value: String?
}

/// Keys in a list of the column, as in the tree: ↑ ↓ move, Space acts on the row, Return types a
/// file's `@path`, Esc closes the preview, and Tab hands the keyboard to it.
@MainActor
private func listKey(_ press: KeyPress, ids: [String], cursor: Pick, model: AppModel,
                     act: (_ id: String, _ typePath: Bool) -> Void) -> KeyPress.Result {
    guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
    let index = cursor.value.flatMap { ids.firstIndex(of: $0) }
    switch press.key {
    case .downArrow, .upArrow:
        guard !ids.isEmpty else { return .handled }
        let step = press.key == .downArrow ? 1 : -1
        cursor.value = ids[index.map { max(0, min(ids.count - 1, $0 + step)) } ?? 0]
    case .space, .return:
        guard let index else { return .handled }
        act(ids[index], press.key == .return)
    case .escape:
        guard model.preview != nil else { return .ignored }
        model.preview = nil
    case .tab:
        guard model.preview != nil, !press.modifiers.contains(.shift) else { return .ignored }
        model.previewFocusRequest += 1
    default:
        return .ignored
    }
    return .handled
}

private struct FilesNote: View {
    let text: String
    var color: Color = Ledger.ink3

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The Changes tab: every file git status marks, by path.
private struct ChangedFilesList: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var files: CheckoutFiles
    let root: String
    @FocusState private var focused: Bool
    @StateObject private var cursor = Pick()

    var body: some View {
        let changed = files.marks.map { ChangedFile(mark: $0.value, path: $0.key) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        if let problem = files.problem {
            FilesNote(text: problem, color: Ledger.failInk)
        } else if files.loaded && changed.isEmpty {
            FilesNote(text: "No changes: the checkout matches its last commit.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(changed, id: \.path) { file in
                            ChangedFileRow(file: file, root: root, indent: 0, picked: cursor.value == file.path) {
                                focused = true
                                cursor.value = file.path
                                model.preview = FileRef(root: root, path: file.path)
                            }
                            .id(file.path)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .modifier(FilesListFocus(tab: .changes, focused: $focused))
                .onKeyPress(phases: .down) { press in
                    listKey(press, ids: changed.map(\.path), cursor: cursor, model: model) { path, typePath in
                        let file = FileRef(root: root, path: path)
                        if typePath, model.terminalTypeable { model.insertMention(file) } else { model.preview = file }
                    }
                }
                .onChange(of: cursor.value) {
                    if let value = cursor.value { proxy.scrollTo(value) }
                }
            }
        }
    }
}

/// The branch's commits, read when the Commits tab shows; a commit's files once it is opened.
final class CommitsState: ObservableObject {
    /// The branch the commits are counted against; nil when they are the latest on this one.
    @Published var base: String?
    @Published var commits: [Commit] = []
    @Published var loaded = false
    @Published var open: Set<String> = []
    @Published var files: [String: [ChangedFile]] = [:]
}

/// The Commits tab: the branch's own commits, newest first; a commit opens to list its files.
private struct CommitsList: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var files: CheckoutFiles
    let root: String
    @ObservedObject var state: CommitsState
    @FocusState private var focused: Bool
    @StateObject private var cursor = Pick()

    var body: some View {
        VStack(spacing: 0) {
            if !state.loaded {
                FilesNote(text: "Reading commits…")
            } else if state.commits.isEmpty {
                FilesNote(text: state.base.map { "No commits on \(files.branch ?? "this branch") yet: it matches \($0)." }
                    ?? "No commits yet.")
            } else {
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Ledger.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 14)
                    .padding(.top, 9)
                    .padding(.bottom, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                list
            }
        }
        // Again when the checkout changes, which a commit, checkout, or rebase does.
        .task(id: "\(root)|\(files.generation)|\(files.branch ?? "")") {
            let read = await CheckoutFiles.commits(root, branch: files.branch)
            guard !Task.isCancelled else { return }
            state.base = read.base
            state.commits = read.commits
            state.loaded = true
        }
    }

    private var summary: String {
        let count = state.commits.count
        let branch = files.branch ?? "HEAD"
        let commits = "\(count) commit\(count == 1 ? "" : "s")"
        if let base = state.base { return "\(commits) on \(branch) that \(base) does not have" }
        return "The latest \(commits) on \(branch)"
    }

    /// Commit rows, and the file rows of each open commit, as the keyboard walks them.
    private var ids: [String] {
        state.commits.flatMap { commit in
            ["c\t" + commit.hash] + (state.open.contains(commit.hash) ? (state.files[commit.hash] ?? []).map { "f\t\(commit.hash)\t\($0.path)" } : [])
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(state.commits) { commit in
                        let open = state.open.contains(commit.hash)
                        CommitRow(commit: commit, open: open, picked: cursor.value == "c\t" + commit.hash) {
                            focused = true
                            cursor.value = "c\t" + commit.hash
                            toggle(commit.hash)
                        }
                        .id("c\t" + commit.hash)
                        if open {
                            if let changed = state.files[commit.hash] {
                                if changed.isEmpty {
                                    Text("No files changed.")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Ledger.ink3)
                                        .padding(.leading, 30)
                                        .frame(height: 24)
                                }
                                ForEach(changed, id: \.path) { file in
                                    let id = "f\t\(commit.hash)\t\(file.path)"
                                    ChangedFileRow(file: file, root: root, indent: 16, picked: cursor.value == id) {
                                        focused = true
                                        cursor.value = id
                                        model.preview = FileRef(root: root, path: file.path)
                                    }
                                    .id(id)
                                }
                            } else {
                                Text("Reading files…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Ledger.ink3)
                                    .padding(.leading, 30)
                                    .frame(height: 24)
                            }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            .modifier(FilesListFocus(tab: .commits, focused: $focused))
            .onKeyPress(phases: .down) { press in
                listKey(press, ids: ids, cursor: cursor, model: model) { id, typePath in
                    let parts = id.split(separator: "\t", maxSplits: 2).map(String.init)
                    if parts[0] == "c" {
                        toggle(parts[1])
                    } else {
                        let file = FileRef(root: root, path: parts[2])
                        if typePath, model.terminalTypeable { model.insertMention(file) } else { model.preview = file }
                    }
                }
            }
            .onChange(of: cursor.value) {
                if let value = cursor.value { proxy.scrollTo(value) }
            }
        }
    }

    private func toggle(_ hash: String) {
        if state.open.contains(hash) {
            state.open.remove(hash)
            return
        }
        state.open.insert(hash)
        guard state.files[hash] == nil else { return }
        let root = root
        Task {
            let changed = await CheckoutFiles.files(of: hash, in: root)
            state.files[hash] = changed
        }
    }
}

/// One commit: its subject, and under it the short hash, author, and when.
private struct CommitRow: View {
    let commit: Commit
    let open: Bool
    let picked: Bool
    let click: () -> Void
    @StateObject private var hover = Flag()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: open ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Ledger.ink3)
                .frame(width: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                    .font(.system(size: 13))
                    .foregroundStyle(Ledger.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(commit.short).font(.system(size: 11.5, design: .monospaced))
                    Text(commit.author).lineLimit(1)
                    Text(commit.when).lineLimit(1)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Ledger.ink3)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(picked ? Ledger.selected : hover.on ? Ledger.wash : Color.clear)
        .overlay(alignment: .leading) {
            if picked { Rectangle().fill(Ledger.run).frame(width: 3) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: click)
        .onHover { hover.on = $0 }
        .contextMenu {
            Button("Copy Hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.hash, forType: .string)
            }
        }
        .help("\(commit.short) \(commit.subject)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
    }
}

/// A changed file: its name in its mark's colour, its folder, and the mark.
private struct ChangedFileRow: View {
    @EnvironmentObject private var model: AppModel
    let file: ChangedFile
    let root: String
    let indent: CGFloat
    let picked: Bool
    let click: () -> Void
    @StateObject private var hover = Flag()

    private var ref: FileRef { FileRef(root: root, path: file.path) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc").font(.system(size: 11.5)).foregroundStyle(Ledger.ink3)
            Text((file.path as NSString).lastPathComponent)
                .foregroundStyle(gitMarkColor(file.mark))
                .lineLimit(1)
                .layoutPriority(1)
            Text((file.path as NSString).deletingLastPathComponent)
                .font(.system(size: 12))
                .foregroundStyle(Ledger.ink3)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 6)
            Text(file.mark.rawValue)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(gitMarkColor(file.mark))
                .accessibilityLabel(gitMarkLabel(file.mark))
        }
        .font(.system(size: 13))
        .padding(.leading, 14 + indent)
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
        .onDrag { NSItemProvider(object: ref.url as NSURL) }
        .contextMenu {
            Button("Preview") { model.preview = ref }
            Button("Insert into Terminal") { model.insertMention(ref) }
                .disabled(!model.terminalTypeable)
            Button("Open") { model.openInEditor(ref) }
            Divider()
            Button("Reveal in Finder") { model.revealInFinder(ref) }
            Button("Copy Path") { model.copyPath(ref) }
        }
        .help(file.path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
    }
}
