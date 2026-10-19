import AppKit
import HubCore
import SwiftTerm
import SwiftUI

/// A daemon-owned terminal drawn with SwiftTerm. Everything SwiftTerm-specific stays in this file,
/// so another renderer (libghostty) can replace it behind the same view.
struct TerminalPane: NSViewRepresentable {
    let target: TerminalTarget
    let client: DaemonClient
    let appearance: TerminalAppearance
    /// False while a modal is up: the terminal gives up the keyboard, so typing and Escape reach
    /// the modal rather than the agent.
    let keyboard: Bool
    /// Draw with SwiftTerm's Metal renderer (Settings > Terminal rendering).
    let gpu: Bool

    func makeCoordinator() -> Coordinator { Coordinator(client: client) }

    func makeNSView(context: Context) -> TerminalView {
        let view = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        view.optionAsMetaKey = true
        context.coordinator.apply(appearance, to: view)
        try? view.setUseMetal(gpu)
        view.terminalDelegate = context.coordinator
        context.coordinator.keyboard = keyboard
        if context.coordinator.show(target, in: view), keyboard { Self.focus(view) }
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        context.coordinator.apply(appearance, to: view)
        // A no-op unless the setting changed; on failure SwiftTerm keeps Core Graphics.
        try? view.setUseMetal(gpu)
        let regained = keyboard && !context.coordinator.keyboard
        context.coordinator.keyboard = keyboard
        if !keyboard {
            Self.unfocus(view)
            context.coordinator.show(target, in: view)
            return
        }
        // Focus moves to the terminal only when it starts showing something new or a modal
        // closes, never on a redraw, so a reply being typed in the ledger keeps its focus.
        if context.coordinator.show(target, in: view) || regained { Self.focus(view) }
    }

    private static func unfocus(_ view: TerminalView) {
        guard let window = view.window, window.firstResponder === view else { return }
        window.makeFirstResponder(nil)
    }

    /// Gives the terminal the keyboard once it is in a window.
    private static func focus(_ view: TerminalView) {
        DispatchQueue.main.async {
            guard let window = view.window, window.firstResponder !== view else { return }
            window.makeFirstResponder(view)
        }
    }

    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let client: DaemonClient
        private var target: TerminalTarget?
        private var socket: HubSocket?
        private weak var view: TerminalView?
        private var generation = 0
        /// The grid size SwiftTerm last reported; 0 until the first layout.
        private var size = (rows: 0, cols: 0)

        private var applied: TerminalAppearance?
        /// Whether the pane last had leave to hold the keyboard.
        var keyboard = true

        /// Sets the font and colours, only when they changed: re-installing colours redraws everything.
        func apply(_ appearance: TerminalAppearance, to view: TerminalView) {
            guard appearance != applied else { return }
            applied = appearance
            let size = CGFloat(appearance.fontSize)
            view.font = NSFont(name: appearance.fontName, size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            let theme = appearance.theme
            view.installColors(theme.ansi.map(Self.terminalColor))
            view.nativeBackgroundColor = Self.nsColor(theme.background)
            view.nativeForegroundColor = Self.nsColor(theme.foreground)
            view.caretColor = Self.nsColor(theme.cursor)
            view.selectedTextBackgroundColor = Self.nsColor(theme.selection)
        }

        static func nsColor(_ hex: String) -> NSColor {
            guard let c = TerminalTheme.rgb(hex) else { return .textColor }
            return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
        }

        static func terminalColor(_ hex: String) -> SwiftTerm.Color {
            let c = TerminalTheme.rgb(hex) ?? (0, 0, 0)
            return SwiftTerm.Color(red: UInt16(c.red * 65535), green: UInt16(c.green * 65535), blue: UInt16(c.blue * 65535))
        }

        init(client: DaemonClient) {
            self.client = client
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(typeMuxKeys(_:)), name: .muxKeys, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(typeText(_:)), name: .typeIntoTerminal, object: nil)
        }

        /// Types text from the Files column into whatever this terminal shows: the agent, or the
        /// multiplexer, which hands it to its focused pane.
        @objc private func typeText(_ note: Notification) {
            // Echo has one terminal on screen at a time; one not in a window is being torn down.
            guard let text = note.object as? Data, let socket, view?.window != nil else { return }
            DispatchQueue.global(qos: .userInteractive).async { try? socket.write(text) }
        }

        /// Types ⌘D's keys into this terminal when it shows a multiplexer in the key window.
        @objc private func typeMuxKeys(_ note: Notification) {
            guard case .shell = target, let keys = note.object as? Data, let socket,
                  view?.window?.isKeyWindow == true else { return }
            DispatchQueue.global(qos: .userInteractive).async { try? socket.write(keys) }
        }

        /// Attaches to `target`, unless already showing it. Returns whether it attached.
        @discardableResult
        func show(_ target: TerminalTarget, in view: TerminalView) -> Bool {
            guard target != self.target else { return false }
            detach()
            self.target = target
            self.view = view
            view.resetToInitialState()
            generation += 1
            let generation = generation
            let (rows, cols) = size
            let client = client
            Thread.detachNewThread { [weak self] in
                do {
                    let socket = try client.attach(target, rows: rows, cols: cols)
                    let current = DispatchQueue.main.sync { () -> Bool in
                        guard let self, self.generation == generation else { return false }
                        self.socket = socket
                        // A layout that landed while attaching has not reached the daemon yet.
                        if self.size.cols >= Self.minimumSize.cols, self.size != (rows, cols) {
                            let size = self.size
                            DispatchQueue.global().async { try? client.resize(target, rows: size.rows, cols: size.cols) }
                        }
                        return true
                    }
                    guard current else { return socket.shutdown() }
                    while let chunk = try socket.readChunk() {
                        let bytes = [UInt8](chunk)
                        DispatchQueue.main.async {
                            guard let self, self.generation == generation else { return }
                            self.view?.feed(byteArray: bytes[...])
                        }
                    }
                    DispatchQueue.main.async {
                        guard let self, self.generation == generation else { return }
                        self.view?.feed(text: "\r\n\u{1b}[2m[terminal ended]\u{1b}[0m\r\n")
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let self, self.generation == generation else { return }
                        self.view?.feed(text: "\u{1b}[2m\(error)\u{1b}[0m\r\n")
                    }
                }
            }
            return true
        }

        func detach() {
            generation += 1
            socket?.shutdown()
            socket = nil
            target = nil
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard let socket else { return }
            let bytes = Data(data)
            DispatchQueue.global(qos: .userInteractive).async { try? socket.write(bytes) }
        }

        /// Smaller than this is a layout passing through, not a size to give the agent: shrinking
        /// the terminal that far would clip its screen.
        private static let minimumSize = (rows: 8, cols: 40)
        private var pendingResize: DispatchWorkItem?

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols >= Self.minimumSize.cols, newRows >= Self.minimumSize.rows else { return }
            size = (newRows, newCols)
            guard let target, socket != nil else { return }
            // Only the size the layout settles on reaches the daemon.
            pendingResize?.cancel()
            let client = client
            let resize = DispatchWorkItem {
                DispatchQueue.global().async { try? client.resize(target, rows: newRows, cols: newCols) }
            }
            pendingResize = resize
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: resize)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
        }
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// SwiftTerm's view, taking dropped files and images: their paths are typed at the cursor, as
/// Terminal.app does, so Claude Code attaches an image or reads a file.
final class DropTerminalView: TerminalView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = Self.paths(from: sender.draggingPasteboard)
        guard !paths.isEmpty else { return false }
        window?.makeFirstResponder(self)
        send(txt: droppedPaths(paths))
        return true
    }

    /// Files as their paths; an image with no file behind it (from a browser, say) saved first.
    private static func paths(from board: NSPasteboard) -> [String] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = board.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            return urls.map(\.path)
        }
        guard let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return [] }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EchoDrops", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("dropped-\(UUID().uuidString.prefix(8)).png")
        guard (try? png.write(to: file)) != nil else { return [] }
        return [file.path]
    }
}
