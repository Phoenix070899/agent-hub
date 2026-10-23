import HubCore
import SwiftUI

/// A Worker's changes as a diff, one file after another. Clicking a line, or moving to it with
/// ↑ and ↓ and pressing Return, leaves a comment on it; the comments go to the Worker, or to the
/// Orchestrator, as one review.
struct ChangesView: View {
    @EnvironmentObject private var model: AppModel
    let repo: String
    let worker: WorkerRow
    /// Local state as an ObservableObject: the command-line tools lack the plugin `@State` needs.
    @StateObject private var state = ChangesState()
    @FocusState private var listFocused: Bool

    private var key: String { AppModel.workerKey(repo, worker) }
    private var comments: [ReviewComment] { model.reviews[key] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            summary
            Divider().overlay(Ledger.rule)
            content
            Divider().overlay(Ledger.rule)
            reviewBar
        }
        .task(id: worker.id) { await load() }
    }

    private var summary: some View {
        let files = state.files
        let added = files.reduce(0) { $0 + $1.additions }
        let removed = files.reduce(0) { $0 + $1.deletions }
        return HStack(spacing: 10) {
            if state.loaded {
                Text("\(files.count) file\(files.count == 1 ? "" : "s") changed")
                    .fontWeight(.semibold)
                Text("+\(added)").foregroundStyle(Ledger.okInk)
                Text("-\(removed)").foregroundStyle(Ledger.failInk)
                Text(worker.branch.map { "on \($0), since it branched" } ?? "uncommitted in the repo, yours included")
                    .foregroundStyle(Ledger.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if state.loading { ProgressView().controlSize(.small) }
            Button("Refresh") { Task { await load() } }
                .buttonStyle(.ledger)
                .disabled(state.loading)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Ledger.paper)
    }

    @ViewBuilder
    private var content: some View {
        if let problem = state.problem {
            message("Echo could not read \(worker.id)'s changes", detail: problem)
        } else if state.loaded && state.files.isEmpty {
            message("No changes yet", detail: "\(worker.id) has not changed any files \(worker.branch == nil ? "in the repo" : "on its branch").")
        } else if !state.loaded {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(Array(state.files.enumerated()), id: \.offset) { index, file in
                            Section {
                                if !state.collapsed.contains(index) { lines(of: file, at: index) }
                            } header: {
                                DiffFileHeader(file: file, collapsed: state.collapsed.contains(index)) {
                                    if state.collapsed.contains(index) { state.collapsed.remove(index) } else { state.collapsed.insert(index) }
                                }
                            }
                        }
                        if state.truncated {
                            Text("The diff is cut at 2 MB. Read the rest in \(worker.branch == nil ? "the repo" : "the worktree").")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Ledger.ink2)
                                .padding(18)
                        }
                    }
                }
                .background(Ledger.paper)
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                // Keys typed in a comment bubble up here too; while one is being written, they are its own.
                .onKeyPress(keys: [.downArrow, .upArrow, .return]) { press in
                    guard state.editing == nil, press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
                    if press.key == .return {
                        guard let cursor = state.cursor else { return .ignored }
                        startComment(at: cursor)
                    } else {
                        moveCursor(press.key == .downArrow ? 1 : -1)
                    }
                    return .handled
                }
                .onChange(of: state.cursor) {
                    if let cursor = state.cursor { proxy.scrollTo(cursor) }
                }
                .onAppear { listFocused = true }
            }
        }
    }

    /// Every line a comment can go on, in order, in files that are open.
    private var commentableLines: [LineRef] {
        state.files.enumerated().flatMap { index, file in
            state.collapsed.contains(index) ? [] : file.lines.enumerated()
                .filter { [.added, .removed, .context].contains($0.element.kind) }
                .map { LineRef(file: index, line: $0.offset) }
        }
    }

    private func moveCursor(_ step: Int) {
        let lines = commentableLines
        guard !lines.isEmpty else { return }
        guard let cursor = state.cursor, let at = lines.firstIndex(of: cursor) else {
            state.cursor = step > 0 ? lines.first : lines.last
            return
        }
        state.cursor = lines[max(0, min(lines.count - 1, at + step))]
    }

    private func startComment(at ref: LineRef) {
        state.cursor = ref
        state.draft = ""
        state.editing = ref
    }

    private func finishComment() {
        state.editing = nil
        listFocused = true
    }

    @ViewBuilder
    private func lines(of file: DiffFile, at index: Int) -> some View {
        if file.binary {
            Text("A binary file; no lines to show.")
                .font(.system(size: 12.5))
                .foregroundStyle(Ledger.ink3)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
        }
        ForEach(Array(file.lines.enumerated()), id: \.offset) { offset, line in
            let ref = LineRef(file: index, line: offset)
            let commentable = line.kind == .added || line.kind == .removed || line.kind == .context
            DiffLineRow(line: line, commentable: commentable, marked: state.editing == ref || state.cursor == ref) {
                guard commentable else { return }
                startComment(at: ref)
            }
            .id(ref)
            ForEach(Array(comments.enumerated()).filter { $0.element.path == file.path && $0.element.line == line }, id: \.offset) { position, comment in
                CommentCard(text: comment.text) {
                    state.draft = comment.text
                    model.reviews[key]?.remove(at: position)
                    state.editing = ref
                } delete: {
                    model.reviews[key]?.remove(at: position)
                }
            }
            if state.editing == ref {
                CommentEditor(draft: $state.draft, cancel: finishComment) {
                    let text = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    model.reviews[key, default: []].append(ReviewComment(path: file.path, line: line, text: text))
                    state.sent = nil
                    finishComment()
                }
            }
        }
    }

    private var reviewBar: some View {
        let live = worker.isActive && worker.live
        return HStack(spacing: 10) {
            if let sent = state.sent, comments.isEmpty {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Ledger.done)
                Text(sent)
            } else if comments.isEmpty {
                Text("Click a line, or pick one with ↑ ↓ and press Return, to comment on it. Comments go to \(live ? "\(worker.id) or " : "")the Orchestrator as one review.")
                    .foregroundStyle(Ledger.ink3)
                    .lineLimit(1)
            } else {
                Text("\(comments.count) comment\(comments.count == 1 ? "" : "s")").fontWeight(.semibold)
                Button("Discard") { model.reviews[key] = nil }
                    .buttonStyle(.ledgerLink)
            }
            Spacer(minLength: 8)
            if !comments.isEmpty {
                if live {
                    Button("Send to the Orchestrator") { send(toWorker: false) }
                        .buttonStyle(.ledger)
                        .help("The Orchestrator decides what happens next, like resuming \(worker.id) or starting a new Task.")
                    Button("Send to \(worker.id)") { send(toWorker: true) }
                        .buttonStyle(.ledgerPrimary)
                        .keyboardShortcut(sendShortcut)
                        .help("Typed into \(worker.id)'s terminal; the Orchestrator is told too. ⇧⌘Return")
                } else {
                    Button("Send to the Orchestrator") { send(toWorker: false) }
                        .buttonStyle(.ledgerPrimary)
                        .keyboardShortcut(sendShortcut)
                        .help("The Orchestrator decides what happens next, like resuming \(worker.id) or starting a new Task. ⇧⌘Return")
                }
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ledger.wash)
    }

    /// ⇧⌘Return, unless a previewed file covers the review and sends its own notes with it.
    private var sendShortcut: KeyboardShortcut? {
        model.preview == nil ? KeyboardShortcut(.return, modifiers: [.command, .shift]) : nil
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(Ledger.ink2)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ledger.paper)
    }

    private func load() async {
        state.loading = true
        do {
            let read = try await model.loadDiff(worker)
            // Another Worker is shown now; its own read fills the view.
            guard !Task.isCancelled else { return }
            state.problem = nil
            state.files = read.files
            state.truncated = read.truncated
        } catch {
            guard !Task.isCancelled else { return }
            state.problem = "\(error)"
        }
        state.loading = false
        state.loaded = true
    }

    private func send(toWorker: Bool) {
        let count = comments.count
        let noun = "\(count) comment\(count == 1 ? "" : "s")"
        model.sendReview(repo: repo, worker: worker, toWorker: toWorker) {
            state.sent = toWorker ? "Sent \(noun) to \(worker.id)." : "Sent \(noun) to the Orchestrator."
        }
    }
}

final class ChangesState: ObservableObject {
    @Published var files: [DiffFile] = []
    @Published var truncated = false
    @Published var loading = false
    /// A first read has come back; until then nothing is drawn, so "No changes" never flashes.
    @Published var loaded = false
    @Published var problem: String?
    /// Files folded to their header, by position.
    @Published var collapsed: Set<Int> = []
    /// The line a comment is being written on.
    @Published var editing: LineRef?
    /// The line ↑ and ↓ moved to; Return comments on it.
    @Published var cursor: LineRef?
    @Published var draft = ""
    /// What the last send did, shown until the next comment.
    @Published var sent: String?
}

struct LineRef: Hashable {
    let file: Int
    let line: Int
}

struct DiffFileHeader: View {
    let file: DiffFile
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Ledger.ink3)
                    .frame(width: 12)
                Text(file.path)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                switch file.change {
                case .added: Text("new").foregroundStyle(Ledger.okInk)
                case .deleted: Text("deleted").foregroundStyle(Ledger.failInk)
                case .modified: EmptyView()
                }
                Spacer(minLength: 8)
                Text("+\(file.additions)").foregroundStyle(Ledger.okInk)
                Text("-\(file.deletions)").foregroundStyle(Ledger.failInk)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ledger.band)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(file.path), \(file.additions) added, \(file.deletions) removed")
        .accessibilityHint(collapsed ? "Shows the file's lines" : "Hides the file's lines")
    }
}

struct DiffLineRow: View {
    let line: DiffLine
    let commentable: Bool
    /// The keyboard cursor is on it, or a comment is being written on it.
    let marked: Bool
    let comment: () -> Void
    @StateObject private var hover = Flag()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Group {
                if commentable && (hover.on || marked) {
                    Image(systemName: "plus.bubble.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Ledger.run)
                        .padding(.trailing, 8)
                } else {
                    number(line.old)
                }
            }
            .frame(width: 44, alignment: .trailing)
            number(line.new).frame(width: 44, alignment: .trailing)
            Text(marker)
                .foregroundStyle(markerColor)
                .frame(width: 22)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .hunk || line.kind == .note ? Ledger.ink3 : Ledger.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1)
        .padding(.trailing, 18)
        .background(background)
        .overlay(alignment: .leading) {
            if marked { Rectangle().fill(Ledger.run).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .onTapGesture(perform: comment)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(commentable ? .isButton : [])
        .accessibilityHint(commentable ? "Comments on this line" : "")
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Ledger.ink3)
            .padding(.trailing, 8)
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "-"
        default: ""
        }
    }

    private var markerColor: Color {
        line.kind == .added ? Ledger.okInk : Ledger.failInk
    }

    private var background: Color {
        switch line.kind {
        case .added: Ledger.okWash
        case .removed: Ledger.failWash
        case .hunk: Ledger.wash
        default: (hover.on || marked) && commentable ? Ledger.selected : Color.clear
        }
    }
}

/// A saved comment under its line.
struct CommentCard: View {
    let text: String
    /// From the left edge: past a diff's gutters, or none under a Markdown block.
    var inset: CGFloat = 110
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 14) {
                Button("Edit", action: edit).buttonStyle(.ledgerLink)
                Button("Delete", action: delete).buttonStyle(.ledgerLink)
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 640, alignment: .leading)
        .background(Ledger.needCard, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.leading, inset)
        .padding(.trailing, inset == 0 ? 0 : 18)
        .padding(.vertical, 6)
    }
}

/// Writing a comment on a line: Return adds it, ⌥Return starts a new line, Escape cancels.
struct CommentEditor: View {
    @Binding var draft: String
    var placeholder = "What should change here?"
    var action = "Add comment"
    var inset: CGFloat = 110
    let cancel: () -> Void
    let save: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(2...8)
                .ledgerField()
                .focused($focused)
                // Return adds the comment, as ⌘Return does; ⌥Return starts a new line.
                .onSubmit(save)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    save()
                    return .handled
                }
                .onExitCommand(perform: cancel)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(.ledger)
                Button(action, action: save)
                    .buttonStyle(.ledgerPrimary)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(maxWidth: 640)
        .padding(.leading, inset)
        .padding(.trailing, inset == 0 ? 0 : 18)
        .padding(.vertical, 8)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}
