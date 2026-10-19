import AppKit
import Highlightr
import HubCore
import PDFKit
import SwiftUI

/// A file over the terminal, under a "Terminal | file" tab strip: code with line numbers and
/// colours, Markdown rendered, images and PDFs as they look. Esc goes back to the terminal, which
/// stays attached underneath. It reads the file again whenever the checkout changes.
struct FilePreviewPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var scheme
    let file: FileRef
    @ObservedObject var files: CheckoutFiles
    @StateObject private var content = PreviewContent()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            tabs
            header
            Divider().overlay(Ledger.rule)
            body(of: content.state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Ledger.paper)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            model.preview = nil
            return .handled
        }
        // From the tree, the tree keeps the keyboard (Space, arrows, Esc); from Quick Open, Esc
        // needs the preview to hold it.
        .onAppear { if !model.treeFocused { focused = true } }
        .task(id: "\(file.root)|\(file.path)|\(files.generation)|\(scheme == .dark)") {
            await content.load(file, dark: scheme == .dark)
        }
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            Button { model.preview = nil } label: {
                HStack(spacing: 6) {
                    Image(systemName: "terminal").font(.system(size: 11))
                    Text("Terminal")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(Ledger.ink2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                Text(file.name).foregroundStyle(Ledger.ink)
                Button { model.preview = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Ledger.ink3)
                .accessibilityLabel("Close \(file.name)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Ledger.paper, in: UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
            Spacer(minLength: 8)
            Text("Esc returns to the terminal")
                .font(.system(size: 12))
                .foregroundStyle(Ledger.ink3)
                .padding(.trailing, 6)
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.top, 6)
        .padding(.horizontal, 8)
        .background(Ledger.band)
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
            if case .markdown = content.state {
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
            PDFPreview(document: document)
        case .text(let lines, let cut):
            CodeLines(lines: lines, changed: content.changed, cut: cut)
        case .markdown(let blocks, let lines, let cut):
            if content.rendered {
                MarkdownView(blocks: blocks)
            } else {
                CodeLines(lines: lines, changed: content.changed, cut: cut)
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

/// Reads and colours the previewed file off the main thread.
@MainActor
final class PreviewContent: ObservableObject {
    enum State {
        case loading
        case missing
        case binary
        case image(NSImage)
        case pdf(PDFDocument)
        case text([AttributedString], cut: Bool)
        case markdown([MarkdownBlock], [AttributedString], cut: Bool)
    }

    @Published var state: State = .loading
    /// Markdown shows rendered unless the human picked Source.
    @Published var rendered = true
    /// Lines that just changed, highlighted for a moment.
    @Published var changed: Set<Int> = []

    private var shown: (path: String, lines: [String])?
    private static let limit = 1_000_000
    /// Bigger text shows without colours, which would take too long.
    private static let colourLimit = 300_000

    func load(_ file: FileRef, dark: Bool) async {
        let url = file.url
        let path = file.path
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
                let lines = Self.colour(text, path: path, dark: dark) ?? plain.map { AttributedString($0) }
                if kind == .markdown {
                    return (.markdown(parseMarkdown(text), lines, cut: cut), plain)
                }
                return (.text(lines, cut: cut), plain)
            }
        }.value
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
    }

    /// The file coloured by Highlightr, one AttributedString per line; nil for plain text.
    nonisolated private static func colour(_ text: String, path: String, dark: Bool) -> [AttributedString]? {
        guard text.utf8.count <= colourLimit, let language = language(for: path),
              let highlightr = Highlightr() else { return nil }
        highlightr.setTheme(to: dark ? "atom-one-dark" : "xcode")
        highlightr.theme.setCodeFont(NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular))
        guard let coloured = highlightr.highlight(text, as: language, fastRender: true) else { return nil }
        var lines: [AttributedString] = []
        let string = coloured.string as NSString
        var start = 0
        while start <= string.length {
            let newline = string.range(of: "\n", range: NSRange(location: start, length: string.length - start))
            let end = newline.location == NSNotFound ? string.length : newline.location
            let range = NSRange(location: start, length: end - start)
            var line = AttributedString(string.substring(with: range))
            coloured.enumerateAttribute(.foregroundColor, in: range) { value, sub, _ in
                guard let color = value as? NSColor,
                      let lower = line.characters.index(line.startIndex, offsetBy: sub.location - start, limitedBy: line.endIndex),
                      let upper = line.characters.index(lower, offsetBy: sub.length, limitedBy: line.endIndex) else { return }
                line[lower..<upper].foregroundColor = Color(nsColor: color)
            }
            lines.append(line)
            if newline.location == NSNotFound { break }
            start = end + 1
        }
        return lines
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
            "cc": "cpp", "css": "css", "scss": "scss", "html": "xml", "xml": "xml", "plist": "xml",
            "svg": "xml", "sql": "sql", "lua": "lua", "php": "php", "cs": "csharp", "dart": "dart",
            "ex": "elixir", "exs": "elixir", "hs": "haskell", "scala": "scala", "vue": "xml",
        ]
        return known[(path as NSString).pathExtension.lowercased()]
    }
}

/// Code with line numbers in a gutter; lines an agent just changed glow for a moment.
private struct CodeLines: View {
    let lines: [AttributedString]
    let changed: Set<Int>
    let cut: Bool

    var body: some View {
        let digits = max(3, String(lines.count).count)
        GeometryReader { geometry in
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(String(index + 1))
                            .foregroundStyle(Ledger.ink3)
                            .frame(width: CGFloat(digits) * 8 + 16, alignment: .trailing)
                            .padding(.trailing, 16)
                        Text(line.characters.isEmpty ? AttributedString(" ") : line)
                            .fixedSize()
                    }
                    .font(.system(size: 12.5, design: .monospaced))
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 1)
                    .background(changed.contains(index) ? Ledger.justChanged : Color.clear)
                }
                if cut {
                    Text("Only the first 1 MB is shown. Open the file to read the rest.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Ledger.ink2)
                        .padding(18)
                }
            }
            .padding(.vertical, 8)
            .textSelection(.enabled)
            // Short files start at the top left, not the middle of the scroll view.
            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
        }
        }
    }
}

/// Markdown as a document: headings, paragraphs, lists, quotes, and code blocks.
private struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .heading(let level, let text):
                        Text(inline(text))
                            .font(.system(size: [26, 19, 16, 14.5, 14, 13.5][min(level, 6) - 1], weight: .semibold))
                            .padding(.top, level <= 2 ? 10 : 4)
                    case .paragraph(let text):
                        Text(inline(text)).lineSpacing(3)
                    case .bullet(let text, let ordered):
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(ordered.map { "\($0)." } ?? "•").foregroundStyle(Ledger.ink2)
                            Text(inline(text)).lineSpacing(3)
                        }
                        .padding(.leading, 6)
                    case .quote(let text):
                        Text(inline(text))
                            .italic()
                            .foregroundStyle(Ledger.ink2)
                            .padding(.leading, 14)
                    case .code(let code, _):
                        Text(code)
                            .font(.system(size: 12.5, design: .monospaced))
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Ledger.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    case .rule:
                        Divider().overlay(Ledger.rule).padding(.vertical, 4)
                    }
                }
            }
            .font(.system(size: 14))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

private struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
