import AppKit
import HubCore
import SwiftUI

/// Text shown as code: the whole file coloured, as the text view draws it, and its lines.
struct Code: @unchecked Sendable {
    let text: NSAttributedString
    let lines: [String]
    /// Where each line starts in `text`, in UTF-16 units.
    let starts: [Int]
}

/// The keys a previewed file answers, whether SwiftUI or the code view holds the keyboard.
enum CodeKey {
    case up, down, `return`, escape, backtab
}

/// Code with line numbers in a gutter, drawn by a text view so only what is on screen is laid
/// out and scrolling stays smooth however long the file. Lines an agent just changed glow for a
/// moment. Each line takes a note for the agent: + in the gutter, or the keyboard cursor and
/// Return; notes and the note being written sit under their line.
/// It does not watch the app's model, so a change elsewhere in the app does not draw it again.
struct CodeView: NSViewRepresentable, Equatable {
    let code: Code
    /// Which read of the file `code` came from; equal versions mean equal code.
    let version: Int
    let changed: Set<Int>
    /// The 1-based line to scroll to and mark.
    let focus: Int?
    let file: FileRef
    /// The notes of this file's checkout, and how to change them.
    let fileNotes: [FileNote]
    let setNotes: ([FileNote]) -> Void
    @ObservedObject var notes: NotesState
    /// Gives the keyboard back to the preview once a note is saved.
    let done: () -> Void
    /// The preview's keys, for when the text view holds the keyboard.
    let key: (CodeKey) -> Bool
    /// This file's tab is the one shown; AppKit views ignore SwiftUI's opacity, so it hides itself.
    let active: Bool

    static func == (a: CodeView, b: CodeView) -> Bool {
        a.version == b.version && a.changed == b.changed && a.focus == b.focus && a.file == b.file
            && a.fileNotes == b.fileNotes && a.notes === b.notes && a.active == b.active
    }

    func makeCoordinator() -> CodeCoordinator { CodeCoordinator() }

    func makeNSView(context: Context) -> NSScrollView { context.coordinator.scroll }

    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update(self) }
}

@MainActor
final class CodeCoordinator {
    let scroll = NSScrollView()
    private let text: CodeTextView
    /// The gutter's width. The text view draws the gutter itself, under its text at its left
    /// edge, so it scrolls sideways with the code: a separate gutter view (an NSRulerView or a
    /// plain sibling) stopped the text and the header above it from drawing inside SwiftUI.
    fileprivate var gutter: CGFloat = 56
    private var view: CodeView?
    private var version = -1
    private var starts: [Int] = [0]
    /// The room under each line that holds notes, as paragraph spacing.
    private var spacing: [Int: CGFloat] = [:]
    private var hosts: [Int: NoteHost] = [:]
    fileprivate var hover: Int? {
        didSet { if hover != oldValue { redrawGutter() } }
    }
    private var focus: Int?
    private var cursor: Int?
    /// Lines glowing after a change, and how strongly, fading out once the change is old.
    private var glowing: Set<Int> = []
    private var glow: CGFloat = 0
    private var fade: Timer?

    private static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    private static let base: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        return style
    }()

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        text = CodeTextView(frame: .zero, textContainer: container)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = true
        text.backgroundColor = NSColor(Ledger.paper)
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        text.autoresizingMask = [.width, .height]
        text.textContainerInset = NSSize(width: 0, height: 8)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        text.coordinator = self
    }

    private func redrawGutter() {
        let visible = text.visibleRect
        text.setNeedsDisplay(NSRect(x: 0, y: visible.minY, width: gutter, height: visible.height))
    }

    func update(_ new: CodeView) {
        view = new
        scroll.isHidden = !new.active
        if new.version != version {
            version = new.version
            starts = new.code.starts
            hosts.values.forEach { $0.removeFromSuperview() }
            hosts = [:]
            spacing = [:]
            gutter = CGFloat(max(3, String(new.code.lines.count).count)) * 8 + 32
            text.textContainerInset = NSSize(width: gutter, height: 8)
            text.textStorage?.setAttributedString(new.code.text)
        }
        layoutNotes()
        glowFor(new.changed)
        text.needsDisplay = true
        if new.focus != focus {
            focus = new.focus
            // On first show the view has no size yet.
            if let line = new.focus { DispatchQueue.main.async { self.center(line - 1) } }
        }
        let marked = new.notes.editing ?? new.notes.cursor
        if marked != cursor {
            cursor = marked
            if let line = marked { reveal(line) }
        }
    }

    // MARK: Lines

    /// The line holding a character, 0-based.
    private func line(of character: Int) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= character { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// A line's rect in the text view, without the room for its notes.
    fileprivate func rect(of line: Int) -> NSRect? {
        guard let layout = text.layoutManager, let storage = text.textStorage, line < starts.count else { return nil }
        var rect: NSRect
        if starts[line] >= storage.length {
            // The empty line after a final newline: one line below the last one.
            guard storage.length > 0 else { return nil }
            let last = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: storage.length - 1), effectiveRange: nil)
            rect = last.offsetBy(dx: 0, dy: last.height - (spacing[line - 1] ?? 0))
        } else {
            rect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: starts[line]), effectiveRange: nil)
        }
        rect.size.height -= spacing[line] ?? 0
        rect.origin.x = 0
        rect.origin.y += text.textContainerOrigin.y
        rect.size.width = max(text.bounds.width, scroll.contentSize.width)
        return rect
    }

    /// The line drawn at a height in the text view, if any.
    fileprivate func line(atY y: CGFloat) -> Int? {
        guard let layout = text.layoutManager, let container = text.textContainer, let storage = text.textStorage,
              storage.length > 0 else { return nil }
        let point = NSPoint(x: 0, y: y - text.textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: point, in: container)
        var found = line(of: layout.characterIndexForGlyph(at: glyph))
        if found + 1 < starts.count, let next = rect(of: found + 1), y >= next.minY { found += 1 }
        guard let rect = rect(of: found), y >= rect.minY, y < rect.maxY else { return nil }
        return found
    }

    /// The lines on screen.
    fileprivate var visibleLines: ClosedRange<Int> {
        guard let layout = text.layoutManager, let container = text.textContainer else { return 0...0 }
        var bounds = scroll.contentView.bounds
        bounds.origin.y -= text.textContainerOrigin.y
        let glyphs = layout.glyphRange(forBoundingRect: bounds, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = line(of: characters.location)
        return first...max(first, min(starts.count - 1, line(of: NSMaxRange(characters)) + 1))
    }

    private func center(_ line: Int) {
        guard let rect = rect(of: line) else { return }
        let height = scroll.contentView.bounds.height
        let y = max(0, min(rect.midY - height / 2, text.bounds.height - height))
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func reveal(_ line: Int) {
        guard var rect = rect(of: line) else { return }
        rect.size.height += spacing[line] ?? 0
        rect.origin.x = scroll.contentView.bounds.minX
        rect.size.width = 1
        text.scrollToVisible(rect.insetBy(dx: 0, dy: -12))
    }

    // MARK: Drawing

    /// The background of a line: the keyboard's line or the search hit, else a recent change.
    private func background(_ line: Int) -> NSColor? {
        guard let view else { return nil }
        if view.notes.cursor == line || view.notes.editing == line { return NSColor(Ledger.selected) }
        if glowing.contains(line), glow > 0 { return NSColor(Ledger.justChanged).withAlphaComponent(glow) }
        if view.focus == line + 1 { return NSColor(Ledger.selected) }
        return nil
    }

    fileprivate func drawBackgrounds(in dirty: NSRect) {
        for line in visibleLines {
            guard let color = background(line), let rect = rect(of: line), rect.intersects(dirty) else { continue }
            color.setFill()
            rect.fill()
        }
    }

    /// The gutter at the text's left edge: each line's number, and + where a note can start.
    /// Row backgrounds already run under it.
    fileprivate func drawGutter(in dirty: NSRect) {
        guard let view, dirty.minX < gutter else { return }
        let left: CGFloat = 0
        let width = gutter
        let number: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor(Ledger.ink3)]
        for line in visibleLines {
            guard let rect = rect(of: line) else { continue }
            let top = rect.minY
            let row = NSRect(x: left, y: top, width: width, height: rect.height)
            guard row.intersects(dirty) else { continue }
            let label = String(line + 1) as NSString
            let size = label.size(withAttributes: number)
            label.draw(at: NSPoint(x: left + width - 16 - size.width, y: top), withAttributes: number)
            let marked = view.notes.cursor == line || view.notes.editing == line
            if hover == line || marked, let plus = Self.plus {
                plus.draw(in: NSRect(x: left + 4 + (16 - plus.size.width) / 2, y: top + (min(rect.height, 18) - plus.size.height) / 2,
                                     width: plus.size.width, height: plus.size.height))
            }
        }
    }

    private static var plus: NSImage? {
        NSImage(systemSymbolName: "plus.bubble.fill", accessibilityDescription: "Add a note")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(Ledger.run)])))
    }

    /// A change glows at once, then fades out when it is no longer new.
    private func glowFor(_ changed: Set<Int>) {
        if !changed.isEmpty {
            fade?.invalidate()
            glowing = changed
            glow = 1
        } else if !glowing.isEmpty, fade == nil, glow == 1 {
            let start = Date()
            fade = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { return timer.invalidate() }
                    let t = min(1, Date().timeIntervalSince(start) / 0.6)
                    self.glow = 1 - (1 - (1 - t) * (1 - t))
                    self.text.needsDisplay = true
                    if t >= 1 {
                        timer.invalidate()
                        self.fade = nil
                        self.glowing = []
                    }
                }
            }
        }
    }

    // MARK: Notes

    fileprivate func startNote(on line: Int) {
        view?.notes.start(at: line)
    }

    fileprivate func key(_ key: CodeKey) -> Bool {
        view?.key(key) ?? false
    }

    /// Puts each line's notes, and the note being written, in the room left under the line.
    private func layoutNotes() {
        guard let view else { return }
        let mine = Dictionary(grouping: view.fileNotes.enumerated().filter { $0.element.path == view.file.path },
                              by: { $0.element.lines.upperBound - 1 })
        var lines = Set(mine.keys)
        if let editing = view.notes.editing { lines.insert(editing) }
        lines = lines.filter { $0 >= 0 && $0 < starts.count }
        for (line, host) in hosts where !lines.contains(line) {
            host.removeFromSuperview()
            hosts[line] = nil
        }
        let width = max(320, scroll.contentSize.width - gutter - 18)
        var room: [Int: CGFloat] = [:]
        for line in lines {
            let host = hosts[line] ?? {
                let host = NoteHost(rootView: AnyView(EmptyView()))
                host.changed = { [weak self] in self?.relayoutSoon() }
                text.addSubview(host)
                hosts[line] = host
                return host
            }()
            host.rootView = AnyView(notesView(line, notes: mine[line] ?? [], view: view))
            host.frame.size.width = width
            room[line] = ceil(host.fittingSize.height)
        }
        if room != spacing, let storage = text.textStorage {
            storage.beginEditing()
            for line in Set(room.keys).union(spacing.keys) where room[line] != spacing[line] {
                let end = line + 1 < starts.count ? starts[line + 1] : storage.length
                guard end > starts[line] else { continue }
                let style = Self.base.mutableCopy() as! NSMutableParagraphStyle
                style.paragraphSpacing = room[line] ?? 0
                storage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: starts[line], length: end - starts[line]))
            }
            storage.endEditing()
            spacing = room
        }
        for (line, host) in hosts {
            guard let rect = rect(of: line) else { continue }
            host.frame = NSRect(x: gutter, y: rect.maxY, width: width, height: room[line] ?? 0)
        }
    }

    private var relayoutPending = false

    /// A note being written grew or shrank; make room once this turn's changes settle.
    private func relayoutSoon() {
        guard !relayoutPending else { return }
        relayoutPending = true
        DispatchQueue.main.async {
            self.relayoutPending = false
            self.layoutNotes()
        }
    }

    private func notesView(_ line: Int, notes mine: [(offset: Int, element: FileNote)], view: CodeView) -> some View {
        let notes = view.notes
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(mine, id: \.offset) { position, note in
                CommentCard(text: note.text, inset: 0) {
                    self.remove(at: position)
                    notes.start(at: line, draft: note.text)
                } delete: {
                    self.remove(at: position)
                }
            }
            if notes.editing == line {
                CommentEditor(draft: Binding(get: { notes.draft }, set: { notes.draft = $0 }),
                              placeholder: "What should the agent know or change here?", action: "Add note", inset: 0) {
                    notes.editing = nil
                    view.done()
                } save: {
                    self.save(on: line)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save(on line: Int) {
        guard let view else { return }
        let text = view.notes.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, line < view.code.lines.count else { return }
        view.setNotes(view.fileNotes + [FileNote(path: view.file.path, lines: (line + 1)...(line + 1),
                                                 quote: [view.code.lines[line]], text: text)])
        view.notes.editing = nil
        view.done()
    }

    private func remove(at position: Int) {
        guard let view, position < view.fileNotes.count else { return }
        var all = view.fileNotes
        all.remove(at: position)
        view.setNotes(all)
    }
}

/// The text view: draws each line's background and the gutter under its text, tracks the line under the pointer for the gutter's +, and hands the preview's keys to it.
final class CodeTextView: NSTextView {
    weak var coordinator: CodeCoordinator?

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        MainActor.assumeIsolated {
            coordinator?.drawBackgrounds(in: rect)
            coordinator?.drawGutter(in: rect)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["code"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: ["code": true]))
    }

    /// In the gutter, + starts a note; the rest of the gutter neither selects nor starts one.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let x = point.x
        let handled = MainActor.assumeIsolated { () -> Bool in
            guard let coordinator, x < coordinator.gutter else { return false }
            if x < 24, let line = coordinator.line(atY: point.y) { coordinator.startNote(on: line) }
            return true
        }
        if !handled { super.mouseDown(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let y = convert(event.locationInWindow, from: nil).y
        MainActor.assumeIsolated { coordinator?.hover = coordinator?.line(atY: y) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        MainActor.assumeIsolated { coordinator?.hover = nil }
    }

    override func keyDown(with event: NSEvent) {
        if let key = CodeKey(event), MainActor.assumeIsolated({ coordinator?.key(key) ?? false }) { return }
        super.keyDown(with: event)
    }
}

/// Notes under a line; tells the code view when its height changes, as an editor's does.
private final class NoteHost: NSHostingView<AnyView> {
    var changed: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        changed?()
    }
}

private extension CodeKey {
    init?(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .option, .control]) else { return nil }
        switch event.keyCode {
        case 126: self = .up
        case 125: self = .down
        case 36, 76: self = .return
        case 53: self = .escape
        case 48 where flags.contains(.shift): self = .backtab
        default: return nil
        }
    }
}
