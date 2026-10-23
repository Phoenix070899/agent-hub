import AppKit
import Highlightr
import HubCore
import PDFKit
import SwiftUI
import WebKit

/// A file over the terminal, under the "Terminal | file | file" tab strip: code with line numbers
/// and colours, Markdown rendered, images and PDFs as they look. Esc goes back to the terminal,
/// which stays attached underneath, and the file keeps its tab. A file that is not the one shown
/// stays loaded but hidden. It reads the file again whenever the checkout changes.
struct FilePreviewPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme
    let file: FileRef
    @ObservedObject var files: CheckoutFiles
    /// This file's tab is the one shown.
    let active: Bool
    @StateObject private var content = PreviewContent()
    @StateObject private var notes = NotesState()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Ledger.rule)
            body(of: content.state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Ledger.paper)
            notesBar
        }
        .background(Ledger.paper)
        .opacity(active ? 1 : 0)
        .disabled(!active)
        .accessibilityHidden(!active)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.escape) { handle(.escape) ? .handled : .ignored }
        .onKeyPress(keys: [.downArrow, .upArrow, .return]) { press in
            guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
            return handle(press.key == .return ? .return : press.key == .downArrow ? .down : .up) ? .handled : .ignored
        }
        .onKeyPress(.tab) { NSEvent.modifierFlags.contains(.shift) && handle(.backtab) ? .handled : .ignored }
        .onChange(of: model.previewFocusRequest) { if active { focused = true } }
        .onChange(of: active) { if active, !model.treeFocused { focused = true } }
        .onChange(of: file) {
            notes.cursor = nil
            notes.editing = nil
        }
        // Blocks and lines are different things to point at.
        .onChange(of: content.rendered) {
            notes.cursor = nil
            notes.editing = nil
        }
        // From the tree, the tree keeps the keyboard (Space, arrows, Esc); from Quick Open, Esc
        // needs the preview to hold it.
        .onAppear { if active, !model.treeFocused { focused = true } }
        // A search hit points at a line, which only the source shows.
        .onChange(of: model.previewLine, initial: true) { if active, model.previewLine != nil { content.rendered = false } }
        .task(id: "\(file.root)|\(file.path)|\(files.generation)|\(scheme == .dark)") {
            await content.load(file, dark: scheme == .dark)
        }
    }

    /// The preview's keys, from SwiftUI or from the code view while it holds the keyboard.
    private func handle(_ key: CodeKey) -> Bool {
        switch key {
        case .escape:
            if notes.editing != nil {
                notes.editing = nil
                focused = true
            } else {
                model.preview = nil
            }
            return true
        // ⇧Tab gives the keyboard back to the tree.
        case .backtab:
            guard active, model.filesShown, notes.editing == nil else { return false }
            model.filesFocusRequest += 1
            return true
        // ↑ and ↓ pick a rendered Markdown block or a line of code, and Return leaves a note on it.
        // Keys typed in a note bubble up here too; while one is being written, they are its own.
        case .up, .down, .return:
            let count = noteTargets
            guard active, count > 0, notes.editing == nil else { return false }
            if key == .return {
                guard let cursor = notes.cursor else { return false }
                notes.start(at: cursor)
            } else {
                let step = key == .down ? 1 : -1
                notes.cursor = notes.cursor.map { max(0, min(count - 1, $0 + step)) } ?? (step > 0 ? 0 : count - 1)
            }
            return true
        }
    }

    /// What a note can point at: the blocks of rendered Markdown, or the lines of any text shown as
    /// code. Zero for images, PDFs, binary files, and a rendered page.
    private var noteTargets: Int {
        switch content.state {
        case .markdown(let blocks, _, let code, _): content.rendered ? blocks.count : code.lines.count
        case .text(let code, _): code.lines.count
        case .html(let code, _): content.rendered ? 0 : code.lines.count
        default: 0
        }
    }

    private var notesOpen: Bool { noteTargets > 0 }

    private func codeView(_ code: Code, cut: Bool) -> some View {
        VStack(spacing: 0) {
            CodeView(code: code, version: content.reloads, changed: content.changed,
                     focus: active ? model.previewLine : nil, file: file, fileNotes: rootNotes,
                     setNotes: setRootNotes, notes: notes, done: { focused = true }, key: handle, active: active)
                .equatable()
            if cut {
                Text("Only the first 1 MB is shown. Open the file to read the rest.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ledger.ink2)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Ledger.wash)
            }
        }
    }

    private func setRootNotes(_ notes: [FileNote]) { model.fileNotes[file.root] = notes }

    private var pageErrors: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().overlay(Ledger.rule)
            HStack {
                Text("\(content.pageErrors.count) error\(content.pageErrors.count == 1 ? "" : "s") in the page")
                    .fontWeight(.semibold)
                    .foregroundStyle(Ledger.fail)
                Spacer(minLength: 8)
                Button("Clear") { content.pageErrors = [] }.buttonStyle(.ledgerLink)
            }
            ForEach(Array(content.pageErrors.suffix(3).enumerated()), id: \.offset) { _, error in
                Text(error)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Ledger.ink2)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 18)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ledger.wash)
    }

    private var rootNotes: [FileNote] { model.fileNotes[file.root] ?? [] }

    /// How to leave a note, or the notes waiting in this checkout and the button that sends them.
    @ViewBuilder
    private var notesBar: some View {
        let notes = rootNotes
        if notesOpen || !notes.isEmpty {
            let name = model.terminalName ?? "the agent"
            HStack(spacing: 10) {
                if notes.isEmpty {
                    Text("Click + beside a block or line, or press Tab, ↑ ↓ and Return, to leave \(name) a note.")
                        .foregroundStyle(Ledger.ink3)
                        .lineLimit(1)
                } else {
                    let files = Set(notes.map(\.path)).count
                    Text("\(notes.count) note\(notes.count == 1 ? "" : "s")\(files > 1 ? " in \(files) files" : "")")
                        .fontWeight(.semibold)
                    Button("Discard") { model.fileNotes[file.root] = nil }
                        .buttonStyle(.ledgerLink)
                }
                Spacer(minLength: 8)
                if !notes.isEmpty {
                    Button("Send to \(name)") { model.sendNotes(root: file.root) }
                        .buttonStyle(.ledgerPrimary)
                        .keyboardShortcut(.return, modifiers: [.command, .shift])
                        .disabled(!model.terminalTypeable)
                        .help(model.terminalTypeable
                              ? "Pasted into \(name)'s terminal as one message. ⇧⌘Return"
                              : "The agent isn't running, so there is no terminal to send to.")
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ledger.wash)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(file.path)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Ledger.ink2)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
                // The path gives way first; the buttons keep their words.
                .layoutPriority(-1)
            if let mark = files.marks[file.path] {
                Text(mark.rawValue)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(mark == .modified || mark == .renamed ? Ledger.changed : mark == .deleted ? Ledger.fail : Ledger.done)
            }
            Spacer(minLength: 8)
            if content.state.hasRenderedView {
                Picker("View", selection: $content.rendered) {
                    Text("Rendered").tag(true)
                    Text("Source").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Button("Reveal in Finder") { model.revealInFinder(file) }
                .buttonStyle(.ledgerLink)
                .fixedSize()
            if case .html = content.state {
                Button("Open in browser") { NSWorkspace.shared.open(file.url) }
                    .buttonStyle(.ledgerLink)
                    .fixedSize()
            }
            Button("Open") { model.openInEditor(file) }
                .buttonStyle(.ledgerLink)
                .fixedSize()
            Button("Insert into terminal") { model.insertMention(file) }
                .buttonStyle(.ledgerPrimary)
                .fixedSize()
                .disabled(!model.terminalTypeable)
                .help(model.terminalTypeable ? "Types @\(file.path) into the terminal" : "The agent isn't running, so there is no terminal to type into.")
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Ledger.paper)
    }

    @ViewBuilder
    private func body(of state: PreviewContent.State) -> some View {
        switch state {
        case .loading:
            Color.clear
        case .missing:
            message("This file is gone", detail: "It was deleted or moved since the tree last read it.")
        case .binary:
            message("No preview", detail: "\(file.name) is a binary file.", actions: true)
        case .image(let image):
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                    .padding(24)
            }
        case .pdf(let document):
            // A web view or PDF view is an AppKit view that opacity does not hide, so it hides
            // itself while another tab is shown. The tab keeps it, so coming back loads nothing.
            PDFPreview(document: document, content: content, active: active)
        case .text(let code, let cut):
            codeView(code, cut: cut)
        case .html(let code, let cut):
            if content.rendered {
                VStack(spacing: 0) {
                    WebPreview(file: file, content: content, active: active)
                    if !content.pageErrors.isEmpty { pageErrors }
                }
            } else {
                codeView(code, cut: cut)
            }
        case .markdown(let blocks, let spans, let code, let cut):
            if content.rendered {
                MarkdownView(blocks: blocks, spans: spans, source: code.lines, version: content.reloads, file: file,
                             fileNotes: rootNotes, setNotes: setRootNotes, notes: notes) { focused = true }
                    .equatable()
            } else {
                codeView(code, cut: cut)
            }
        }
    }

    private func message(_ title: String, detail: String, actions: Bool = false) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(Ledger.ink2)
            if actions {
                HStack(spacing: 8) {
                    Button("Open") { model.openInEditor(file) }.buttonStyle(.ledgerPrimary)
                    Button("Reveal in Finder") { model.revealInFinder(file) }.buttonStyle(.ledger)
                }
                .padding(.top, 4)
            }
        }
        .padding(30)
    }
}

/// The strip over the main panel: the Terminal, then a tab for each open file of this checkout.
struct PreviewTabs: View {
    @EnvironmentObject private var model: AppModel
    let files: [FileRef]

    var body: some View {
        HStack(spacing: 2) {
            tab(active: model.preview == nil) {
                Button { model.preview = nil } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal").font(.system(size: 11))
                        Text("Terminal")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ForEach(files, id: \.self) { file in
                tab(active: model.preview == file, file: file) {
                    HStack(spacing: 8) {
                        Button { model.preview = file } label: {
                            Text(file.name).lineLimit(1).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(file.path)
                        Button { model.closePreview(file) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Ledger.ink3)
                        .accessibilityLabel("Close \(file.name)")
                    }
                }
            }
            Spacer(minLength: 8)
            if model.preview != nil {
                Text("Esc returns to the terminal")
                    .font(.system(size: 12))
                    .foregroundStyle(Ledger.ink3)
                    .padding(.trailing, 6)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.top, 6)
        .padding(.horizontal, 8)
        .background(Ledger.band)
    }

    /// A file's tab can be dragged onto another to reorder.
    @ViewBuilder
    private func tab<Content: View>(active: Bool, file: FileRef? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        let look = content()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(active ? Ledger.ink : Ledger.ink2)
            .background(active ? Ledger.paper : Color.clear, in: UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
        if let file {
            look
                .draggable(file.root + "\n" + file.path)
                .dropDestination(for: String.self) { items, _ in
                    guard let item = items.first, let split = item.firstIndex(of: "\n") else { return false }
                    model.moveTab(FileRef(root: String(item[..<split]), path: String(item[item.index(after: split)...])), onto: file)
                    return true
                }
        } else {
            look
        }
    }
}

/// Reads and colours the previewed file off the main thread.
@MainActor
final class PreviewContent: ObservableObject {
    enum State {
        case loading
        case missing
        case binary
        case image(NSImage)
        case pdf(PDFDocument)
        case text(Code, cut: Bool)
        /// The blocks, the source lines each was read from, and the source coloured.
        case markdown([MarkdownBlock], [ClosedRange<Int>], Code, cut: Bool)
        /// The source coloured; the page itself is drawn by the web view from the file.
        case html(Code, cut: Bool)

        /// Markdown and HTML can show rendered or as source.
        var hasRenderedView: Bool {
            switch self {
            case .markdown, .html: true
            default: false
            }
        }
    }

    @Published var state: State = .loading
    /// Markdown shows rendered unless the human picked Source.
    @Published var rendered = true
    /// Counts reads, so the web view loads the page again when the file changes.
    @Published var reloads = 0
    /// Errors the page reported (script errors, failed loads, `console.error`), newest last.
    @Published var pageErrors: [String] = []
    /// Where the page was scrolled to, so a reload or coming back to the tab keeps the place.
    var webScroll: (x: Double, y: Double) = (0, 0)
    /// Lines that just changed, highlighted for a moment.
    @Published var changed: Set<Int> = []
    /// The page's web view, made on first show and kept for the tab's life, so showing the tab
    /// again starts no web process and loads nothing.
    private(set) lazy var page = WebPage(content: self)
    private(set) lazy var pdfView: PDFView = {
        let view = PDFView()
        view.autoScales = true
        return view
    }()

    private var shown: (path: String, lines: [String])?
    /// What the last read saw, so a change elsewhere in the checkout does not read this file again.
    private var stamp: Stamp?

    private struct Stamp: Equatable {
        let path: String
        let modified: Date?
        let size: Int?
        let dark: Bool
    }
    nonisolated private static let limit = 1_000_000
    /// Bigger text shows without colours, which would take too long.
    nonisolated private static let colourLimit = 300_000

    func load(_ file: FileRef, dark: Bool) async {
        let url = file.url
        let path = file.path
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = Stamp(path: url.path, modified: values?.contentModificationDate, size: values?.fileSize, dark: dark)
        guard stamp != self.stamp || values == nil else { return }
        let read = await Task.detached(priority: .userInitiated) { () -> (State, [String]?) in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return (.missing, nil) }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: Self.limit + 1)) ?? Data()
            switch fileKind(path: path, head: data) {
            case .binary: return (.binary, nil)
            case .image:
                return (NSImage(contentsOf: url).map(State.image) ?? .binary, nil)
            case .pdf:
                return (PDFDocument(url: url).map(State.pdf) ?? .binary, nil)
            case let kind:
                let cut = data.count > Self.limit
                let text = String(decoding: data.prefix(Self.limit), as: UTF8.self)
                let plain = text.components(separatedBy: "\n")
                let code = Self.code(text, lines: plain, path: path, dark: dark)
                if kind == .html { return (.html(code, cut: cut), plain) }
                if kind == .markdown {
                    let read = parseMarkdownLines(text)
                    warmInline(read.blocks)
                    return (.markdown(read.blocks, read.lines, code, cut: cut), plain)
                }
                return (.text(code, cut: cut), plain)
            }
        }.value
        // A newer read took over while this one ran.
        guard !Task.isCancelled else { return }
        self.stamp = stamp
        if let new = read.1, let old = shown, old.path == path {
            let lines = changedLines(old: old.lines, new: new)
            if !lines.isEmpty {
                changed = lines
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    withAnimation(.easeOut(duration: 0.6)) { self?.changed = [] }
                }
            }
        } else {
            changed = []
        }
        shown = read.1.map { (path, $0) }
        state = read.0
        reloads += 1
        pageErrors = []
    }

    /// The file as the code view shows it: coloured by Highlightr when small enough and in a
    /// known language, else plain; in the code font either way.
    nonisolated private static func code(_ text: String, lines: [String], path: String, dark: Bool) -> Code {
        let all = NSRange(location: 0, length: (text as NSString).length)
        let out: NSMutableAttributedString
        if text.utf8.count <= colourLimit, let language = language(for: path),
           let coloured = Highlighters.shared.colour(text, as: language, dark: dark), coloured.string == text {
            out = NSMutableAttributedString(attributedString: coloured)
            out.removeAttribute(.backgroundColor, range: all)
        } else {
            out = NSMutableAttributedString(string: text, attributes: [.foregroundColor: NSColor.labelColor])
        }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        out.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular), .paragraphStyle: style], range: all)
        var starts = [0]
        for (offset, unit) in text.utf16.enumerated() where unit == 0x0A { starts.append(offset + 1) }
        return Code(text: out, lines: lines, starts: starts)
    }

    /// highlight.js's name for a file's language, from its extension; nil leaves it plain.
    nonisolated private static func language(for path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == "dockerfile" { return "dockerfile" }
        if name == "makefile" { return "makefile" }
        let known: [String: String] = [
            "swift": "swift", "rs": "rust", "py": "python", "js": "javascript", "mjs": "javascript",
            "cjs": "javascript", "jsx": "javascript", "ts": "typescript", "tsx": "typescript",
            "json": "json", "yml": "yaml", "yaml": "yaml", "toml": "ini", "ini": "ini", "md": "markdown",
            "markdown": "markdown", "sh": "bash", "zsh": "bash", "bash": "bash", "go": "go", "java": "java",
            "kt": "kotlin", "rb": "ruby", "c": "c", "h": "c", "m": "objectivec", "cpp": "cpp", "hpp": "cpp",
            "cc": "cpp", "css": "css", "scss": "scss", "html": "xml", "htm": "xml", "xml": "xml", "plist": "xml",
            "svg": "xml", "sql": "sql", "lua": "lua", "php": "php", "cs": "csharp", "dart": "dart",
            "ex": "elixir", "exs": "elixir", "hs": "haskell", "scala": "scala", "vue": "xml",
        ]
        return known[(path as NSString).pathExtension.lowercased()]
    }
}

/// One Highlightr per theme, made once: each holds a JavaScript context that is slow to set up.
/// One context is not safe to share between threads, so colouring takes turns.
private final class Highlighters: @unchecked Sendable {
    static let shared = Highlighters()
    private let lock = NSLock()
    private var made: [Bool: Highlightr] = [:]

    func colour(_ text: String, as language: String, dark: Bool) -> NSAttributedString? {
        lock.lock()
        defer { lock.unlock() }
        if made[dark] == nil, let highlightr = Highlightr() {
            highlightr.setTheme(to: dark ? "atom-one-dark" : "xcode")
            highlightr.theme.setCodeFont(NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular))
            made[dark] = highlightr
        }
        return made[dark]?.highlight(text, as: language, fastRender: true)
    }
}

extension PreviewContent {
    /// Sets up the highlighter for this theme in the background, so the first file opened does
    /// not wait for its JavaScript context.
    nonisolated static func warm(dark: Bool) {
        Task.detached(priority: .utility) {
            _ = Highlighters.shared.colour("let a = 1", as: "swift", dark: dark)
        }
    }
}

/// The block the keyboard is on and the note being written, for one previewed file.
final class NotesState: ObservableObject {
    /// The block ↑ and ↓ moved to; Return leaves a note on it.
    @Published var cursor: Int?
    /// The block a note is being written on.
    @Published var editing: Int?
    @Published var draft = ""

    func start(at block: Int, draft: String = "") {
        cursor = block
        self.draft = draft
        editing = block
    }
}

/// Markdown as a document: front matter, headings, paragraphs, lists, quotes, tables, and code.
/// Each block takes notes for the agent: + beside it, or the keyboard cursor and Return.
/// It does not watch the app's model, so a change elsewhere in the app does not draw it again.
private struct MarkdownView: View, Equatable {
    let blocks: [MarkdownBlock]
    /// The source lines each block was read from.
    let spans: [ClosedRange<Int>]
    let source: [String]
    /// Which read of the file the blocks came from; equal versions mean equal blocks.
    let version: Int
    let file: FileRef
    /// The notes of this file's checkout, and how to change them.
    let fileNotes: [FileNote]
    let setNotes: ([FileNote]) -> Void
    @ObservedObject var notes: NotesState
    /// Gives the keyboard back to the preview once a note is saved.
    let done: () -> Void

    static func == (a: MarkdownView, b: MarkdownView) -> Bool {
        a.version == b.version && a.file == b.file && a.fileNotes == b.fileNotes && a.notes === b.notes
    }

    var body: some View {
        let all = fileNotes
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    VStack(alignment: .leading, spacing: 0) {
                        NoteableBlock(marked: notes.cursor == index || notes.editing == index) {
                            notes.start(at: index)
                        } content: {
                            MarkdownBlockView(block: block)
                        }
                        ForEach(Array(all.enumerated()).filter { $0.element.path == file.path && $0.element.lines == spans[index] },
                                id: \.offset) { position, note in
                            CommentCard(text: note.text, inset: 0) {
                                remove(at: position)
                                notes.start(at: index, draft: note.text)
                            } delete: {
                                remove(at: position)
                            }
                        }
                        if notes.editing == index {
                            CommentEditor(draft: $notes.draft, placeholder: "What should the agent know or change here?",
                                          action: "Add note", inset: 0) {
                                notes.editing = nil
                                done()
                            } save: {
                                save(on: index)
                            }
                        }
                    }
                    .padding(.top, index == 0 ? 0 : MarkdownBlockView.gap(blocks[index - 1], block))
                    .id(index)
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(Ledger.ink)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: notes.cursor) {
            if let cursor = notes.cursor { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(cursor) } }
        }
        }
    }

    private func save(on index: Int) {
        let text = notes.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let span = spans[index]
        let quote = Array(source[min(span.lowerBound - 1, source.count)..<min(span.upperBound, source.count)])
        setNotes(fileNotes + [FileNote(path: file.path, lines: span, quote: quote, text: text)])
        notes.editing = nil
        done()
    }

    private func remove(at position: Int) {
        var all = fileNotes
        all.remove(at: position)
        setNotes(all)
    }
}

/// One Markdown block drawn as a document: the shared look of a previewed file and a Final Report.
struct MarkdownBlockView: View {
    let block: MarkdownBlock
    /// Extra space between wrapped lines of text.
    var leading: CGFloat = 4
    /// Inline `code`, a little smaller than the text around it.
    var codeSize: CGFloat = 12.5

    var body: some View { view(block) }

    /// Items of one list sit close; other blocks get room, headings the most.
    static func gap(_ previous: MarkdownBlock, _ block: MarkdownBlock) -> CGFloat {
        switch (previous, block) {
        case (.bullet, .bullet): 5
        case (_, .heading(let level, _)): level <= 2 ? 28 : 20
        case (.heading, _): 10
        default: 14
        }
    }

    @ViewBuilder
    private func view(_ block: MarkdownBlock) -> some View {
        switch block {
        case .frontMatter(let yaml):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 4) {
                ForEach(Array(frontMatterFields(yaml).enumerated()), id: \.offset) { _, field in
                    GridRow {
                        Text(field.key).foregroundStyle(Ledger.ink3)
                        Text(field.value).foregroundStyle(Ledger.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ledger.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        case .heading(let level, let text):
            VStack(alignment: .leading, spacing: 8) {
                Text(inline(text, code: codeSize))
                    .font(.system(size: [26, 20, 16.5, 15, 14, 13.5][min(level, 6) - 1], weight: .semibold))
                    .foregroundStyle(level == 6 ? Ledger.ink2 : Ledger.ink)
                if level <= 2 { Rectangle().fill(Ledger.rule).frame(height: 1) }
            }
        case .paragraph(let text):
            Text(inline(text, code: codeSize)).lineSpacing(leading)
        case .bullet(let text, let ordered, let depth, let checked):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                marker(ordered: ordered, depth: depth, checked: checked)
                Text(inline(text, code: codeSize))
                    .lineSpacing(leading)
                    .foregroundStyle(checked == true ? Ledger.ink2 : Ledger.ink)
            }
            .padding(.leading, 4 + CGFloat(depth) * 22)
        case .quote(let text):
            HStack(spacing: 12) {
                Rectangle().fill(Ledger.rule).frame(width: 3)
                Text(inline(text, code: codeSize)).lineSpacing(leading).foregroundStyle(Ledger.ink2)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let code, let language):
            VStack(alignment: .leading, spacing: 6) {
                if !language.isEmpty {
                    Text(language).font(.system(size: 11)).foregroundStyle(Ledger.ink3)
                }
                ScrollView(.horizontal) {
                    Text(code)
                        .font(.system(size: 12.5, design: .monospaced))
                        .lineSpacing(2)
                        .fixedSize()
                }
                .scrollIndicators(.hidden)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ledger.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        case .table(let header, let rows, let alignments):
            MarkdownTable(header: header, rows: rows, alignments: alignments)
        case .rule:
            Rectangle().fill(Ledger.rule).frame(height: 1).padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func marker(ordered: Int?, depth: Int, checked: Bool?) -> some View {
        if let checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 12.5))
                .foregroundStyle(checked ? Ledger.done : Ledger.ink3)
        } else if let ordered {
            Text("\(ordered).").monospacedDigit().foregroundStyle(Ledger.ink2)
        } else {
            Text(["•", "◦", "▪"][depth % 3]).foregroundStyle(Ledger.ink2)
        }
    }
}

/// One rendered block that takes a note: + in the margin on hover, and a tint while the keyboard
/// cursor is on it. The block's text stays selectable, so only + starts a note.
private struct NoteableBlock<Content: View>: View {
    let marked: Bool
    let note: () -> Void
    @ViewBuilder let content: Content
    @StateObject private var hover = Flag()

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if marked {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Ledger.selected).padding(-6)
                }
            }
            .overlay(alignment: .topLeading) {
                if hover.on || marked {
                    Button(action: note) {
                        Image(systemName: "plus.bubble.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Ledger.run)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: -32, y: -3)
                    .help("Leave a note on this for the agent")
                    .accessibilityLabel("Add a note")
                }
            }
            // The margin + sits in counts as the block, so the pointer can reach it.
            .padding(.leading, 34)
            .contentShape(Rectangle())
            .padding(.leading, -34)
            .onHover { hover.on = $0 }
    }
}

/// A Markdown table: a header band, ruled rows, each column aligned as its delimiter says.
/// Columns take the width their text needs; when that is more than the page, long cells wrap.
private struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    let alignments: [TableAlignment]

    var body: some View {
        TableLayout(columns: header.count) {
            ForEach(header.indices, id: \.self) { column in
                cell(header[column], row: -1, column: column).fontWeight(.semibold)
            }
            ForEach(rows.indices, id: \.self) { row in
                ForEach(header.indices, id: \.self) { column in
                    cell(rows[row][column], row: row, column: column)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Ledger.rule))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func cell(_ text: String, row: Int, column: Int) -> some View {
        let alignment: Alignment = switch alignments[column] {
        case .leading: .topLeading
        case .center: .top
        case .trailing: .topTrailing
        }
        return Text(inlineMarkdown(text))
            .font(.system(size: 13))
            .lineSpacing(2)
            .multilineTextAlignment(alignment == .topTrailing ? .trailing : alignment == .top ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            // Every cell fills its row, so the header band and the rules run edge to edge.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .background(row < 0 ? Ledger.wash : Color.clear)
            .overlay(alignment: .top) {
                if row >= 0 { Rectangle().fill(Ledger.rule).frame(height: 1) }
            }
    }
}

/// Cells in rows of `columns`: each column as wide as its widest cell, up to 420 pt. When the
/// columns need more than the width offered, narrow columns keep their width and the rest share
/// what is left evenly, so short labels never break mid-word; rows grow to fit wrapped text.
private struct TableLayout: Layout {
    let columns: Int

    private func widths(_ cells: Subviews, offered: CGFloat?) -> [CGFloat] {
        var ideal = Array(repeating: CGFloat(0), count: columns)
        for (index, cell) in cells.enumerated() {
            ideal[index % columns] = max(ideal[index % columns], ceil(cell.sizeThatFits(.unspecified).width))
        }
        ideal = ideal.map { min($0, 420) }
        guard let offered, ideal.reduce(0, +) > offered else { return ideal }
        var widths = ideal
        var left = offered
        var open = Array(ideal.indices).sorted { ideal[$0] < ideal[$1] }
        while let narrowest = open.first, ideal[narrowest] <= left / CGFloat(open.count) {
            left -= ideal[narrowest]
            open.removeFirst()
        }
        for column in open { widths[column] = max(60, floor(left / CGFloat(open.count))) }
        return widths
    }

    private func heights(_ cells: Subviews, widths: [CGFloat]) -> [CGFloat] {
        var heights = Array(repeating: CGFloat(0), count: (cells.count + columns - 1) / columns)
        for (index, cell) in cells.enumerated() {
            let size = cell.sizeThatFits(ProposedViewSize(width: widths[index % columns], height: nil))
            heights[index / columns] = max(heights[index / columns], ceil(size.height))
        }
        return heights
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard columns > 0 else { return .zero }
        let widths = widths(subviews, offered: proposal.width)
        return CGSize(width: widths.reduce(0, +), height: heights(subviews, widths: widths).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard columns > 0 else { return }
        let widths = widths(subviews, offered: bounds.width)
        let heights = heights(subviews, widths: widths)
        var y = bounds.minY
        for row in heights.indices {
            var x = bounds.minX
            for column in 0..<columns where row * columns + column < subviews.count {
                subviews[row * columns + column].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                                       proposal: ProposedViewSize(width: widths[column], height: heights[row]))
                x += widths[column]
            }
            y += heights[row]
        }
    }
}

private func inline(_ text: String, code: CGFloat = 12.5) -> AttributedString { inlineMarkdown(text, code: code) }

/// Front matter as "key: value" rows; an indented line or "- item" carries on the field above.
private func frontMatterFields(_ yaml: String) -> [(key: String, value: String)] {
    var fields: [(key: String, value: String)] = []
    for line in yaml.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !line.hasPrefix(" "), !trimmed.hasPrefix("- "), let colon = trimmed.firstIndex(of: ":") {
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields.append((String(trimmed[..<colon]), value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))))
        } else if !fields.isEmpty {
            let item = trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed
            let last = fields[fields.count - 1]
            fields[fields.count - 1].value = last.value.isEmpty ? item : last.value + ", " + item
        } else {
            fields.append(("", trimmed))
        }
    }
    return fields
}

/// Inline Markdown (bold, italics, code, links, strikethrough) with code spans set in mono on a
/// tint, and `<br>` as a line break. Each text is parsed once, so redrawing a long document costs
/// no parsing; a previewed file's blocks are parsed off the main thread as it loads.
private func inlineMarkdown(_ text: String, code: CGFloat = 12.5) -> AttributedString {
    let key = "\(code)|\(text)" as NSString
    if let hit = InlineCache.shared.object(forKey: key) { return hit.value }
    let value = parseInline(text, code: code)
    InlineCache.shared.setObject(InlineCache.Entry(value), forKey: key)
    return value
}

/// Parses the inline text of each block, so drawing the document finds them ready.
private func warmInline(_ blocks: [MarkdownBlock]) {
    for block in blocks {
        switch block {
        case .heading(_, let text), .paragraph(let text), .bullet(let text, _, _, _), .quote(let text):
            _ = inlineMarkdown(text)
        case .table(let header, let rows, _):
            for cell in header + rows.joined() { _ = inlineMarkdown(cell) }
        case .frontMatter, .code, .rule:
            break
        }
    }
}

private enum InlineCache {
    final class Entry {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    /// NSCache is safe to use from any thread.
    nonisolated(unsafe) static let shared: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 20_000
        return cache
    }()
}

private func parseInline(_ text: String, code: CGFloat) -> AttributedString {
    var source = text
    for tag in ["<br>", "<br/>", "<br />"] { source = source.replacingOccurrences(of: tag, with: "\n") }
    guard var out = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    else { return AttributedString(source) }
    for run in out.runs where run.inlinePresentationIntent?.contains(.code) == true {
        out[run.range].font = .system(size: code, design: .monospaced)
        out[run.range].backgroundColor = Ledger.wash
    }
    return out
}

private struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument
    let content: PreviewContent
    let active: Bool

    func makeNSView(context: Context) -> PDFView { content.pdfView }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
        view.isHidden = !active
    }
}

/// An HTML file drawn by the tab's web view, which hides while another tab is shown.
private struct WebPreview: NSViewRepresentable {
    let file: FileRef
    let content: PreviewContent
    let active: Bool

    func makeNSView(context: Context) -> WKWebView { content.page.view }

    func updateNSView(_ view: WKWebView, context: Context) {
        view.isHidden = !active
        content.page.show(file, reloads: content.reloads)
    }
}

/// An HTML file in a web view, with the checkout readable so its styles, scripts, and images
/// load. Links to other sites open in the browser. The page reports its scroll position and its
/// errors back, so a reload keeps the place and the errors show under the page.
@MainActor
final class WebPage: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let view: WKWebView
    private weak var content: PreviewContent?
    private var loaded: (file: FileRef?, reloads: Int) = (nil, -1)

    init(content: PreviewContent) {
        self.content = content
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        // The controller holds its handler strongly; through a weak hop, the page and its view
        // go when the tab does.
        configuration.userContentController.add(WeakHandler(self), name: "echo")
        view.navigationDelegate = self
    }

    /// Loads the file unless this read of it is already shown.
    func show(_ file: FileRef, reloads: Int) {
        guard loaded.file != file || loaded.reloads != reloads else { return }
        loaded = (file, reloads)
        view.loadFileURL(file.url, allowingReadAccessTo: URL(fileURLWithPath: file.root))
    }

    private static let script = """
    (function () {
      const post = (kind, v) => window.webkit.messageHandlers.echo.postMessage({ kind: kind, v: v });
      window.addEventListener('error', function (e) {
        if (e.target && e.target !== window) { post('error', 'Failed to load ' + (e.target.src || e.target.href)); return; }
        post('error', (e.message || 'Error') + (e.filename ? ' (' + e.filename.split('/').pop() + ':' + e.lineno + ')' : ''));
      }, true);
      window.addEventListener('unhandledrejection', function (e) {
        post('error', 'Unhandled rejection: ' + (e.reason && e.reason.message || e.reason));
      });
      const consoleError = console.error;
      console.error = function () {
        post('error', Array.from(arguments).map(String).join(' '));
        consoleError.apply(console, arguments);
      };
      let timer;
      window.addEventListener('scroll', function () {
        clearTimeout(timer);
        timer = setTimeout(function () { post('scroll', [window.scrollX, window.scrollY]); }, 100);
      }, { passive: true });
    })();
    """

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let content, let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        if kind == "scroll", let at = (body["v"] as? [NSNumber])?.map(\.doubleValue), at.count == 2 {
            content.webScroll = (at[0], at[1])
        } else if kind == "error", let text = body["v"] as? String, content.pageErrors.last != text {
            content.pageErrors = Array((content.pageErrors + [text]).suffix(20))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let (x, y) = content?.webScroll else { return }
        if x != 0 || y != 0 { webView.evaluateJavaScript("window.scrollTo(\(x), \(y))") }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, action.navigationType == .linkActivated, !url.isFileURL {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: WebPage?

        init(_ target: WebPage) { self.target = target }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            // WebKit delivers messages on the main thread.
            MainActor.assumeIsolated { target?.userContentController(controller, didReceive: message) }
        }
    }
}
