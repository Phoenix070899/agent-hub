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
        // A search hit points at a line, which only the source shows.
        .onChange(of: model.previewLine, initial: true) { if model.previewLine != nil { content.rendered = false } }
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
            CodeLines(lines: lines, changed: content.changed, cut: cut, focus: model.previewLine)
        case .markdown(let blocks, let lines, let cut):
            if content.rendered {
                MarkdownView(blocks: blocks)
            } else {
                CodeLines(lines: lines, changed: content.changed, cut: cut, focus: model.previewLine)
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
    /// The 1-based line to scroll to and mark.
    var focus: Int?

    var body: some View {
        let digits = max(3, String(lines.count).count)
        GeometryReader { geometry in
        ScrollViewReader { proxy in
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
                    .background(changed.contains(index) ? Ledger.justChanged
                                : focus == index + 1 ? Ledger.selected : Color.clear)
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
        .onChange(of: focus, initial: true) {
            if let focus { proxy.scrollTo(focus - 1, anchor: .center) }
        }
        }
        }
    }
}

/// Markdown as a document: front matter, headings, paragraphs, lists, quotes, tables, and code.
private struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    view(block)
                        .padding(.top, index == 0 ? 0 : gap(blocks[index - 1], block))
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(Ledger.ink)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Items of one list sit close; other blocks get room, headings the most.
    private func gap(_ previous: MarkdownBlock, _ block: MarkdownBlock) -> CGFloat {
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
                Text(inline(text))
                    .font(.system(size: [26, 20, 16.5, 15, 14, 13.5][min(level, 6) - 1], weight: .semibold))
                    .foregroundStyle(level == 6 ? Ledger.ink2 : Ledger.ink)
                if level <= 2 { Rectangle().fill(Ledger.rule).frame(height: 1) }
            }
        case .paragraph(let text):
            Text(inline(text)).lineSpacing(4)
        case .bullet(let text, let ordered, let depth, let checked):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                marker(ordered: ordered, depth: depth, checked: checked)
                Text(inline(text))
                    .lineSpacing(4)
                    .foregroundStyle(checked == true ? Ledger.ink2 : Ledger.ink)
            }
            .padding(.leading, 4 + CGFloat(depth) * 22)
        case .quote(let text):
            HStack(spacing: 12) {
                Rectangle().fill(Ledger.rule).frame(width: 3)
                Text(inline(text)).lineSpacing(4).foregroundStyle(Ledger.ink2)
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

/// A Markdown table: a header band, ruled rows, each column aligned as its delimiter says.
/// Long cells wrap; a table wider than the page scrolls sideways.
private struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    let alignments: [TableAlignment]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        cell(header[column], column: column).fontWeight(.semibold)
                    }
                }
                .background(Ledger.wash)
                ForEach(rows.indices, id: \.self) { row in
                    Rectangle().fill(Ledger.rule).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(header.indices, id: \.self) { column in
                            cell(rows[row][column], column: column)
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Ledger.rule))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .scrollIndicators(.hidden)
    }

    private func cell(_ text: String, column: Int) -> some View {
        let alignment: Alignment = switch alignments[column] {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        return Text(inlineMarkdown(text))
            .font(.system(size: 13))
            .lineSpacing(2)
            .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .frame(maxWidth: 340, alignment: alignment)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .gridColumnAlignment(alignment.horizontal)
    }
}

private func inline(_ text: String) -> AttributedString { inlineMarkdown(text) }

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
/// tint, and `<br>` as a line break.
private func inlineMarkdown(_ text: String) -> AttributedString {
    var source = text
    for tag in ["<br>", "<br/>", "<br />"] { source = source.replacingOccurrences(of: tag, with: "\n") }
    guard var out = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    else { return AttributedString(source) }
    for run in out.runs where run.inlinePresentationIntent?.contains(.code) == true {
        out[run.range].font = .system(size: 12.5, design: .monospaced)
        out[run.range].backgroundColor = Ledger.wash
    }
    return out
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
