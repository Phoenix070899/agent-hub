import AppKit
import HubCore
import SwiftUI
import WebKit

/// A daemon-owned terminal drawn with xterm.js in a web view. Everything renderer-specific stays
/// in this file and `Terminal/`, so another renderer (libghostty) can replace it behind the same view.
struct TerminalPane: NSViewRepresentable {
    let target: TerminalTarget
    let client: DaemonClient
    let appearance: TerminalAppearance
    /// False while a modal is up: the terminal gives up the keyboard, so typing and Escape reach
    /// the modal rather than the agent.
    let keyboard: Bool
    /// Changes when the human selects what this pane shows, even if it already shows it.
    let focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(client: client) }

    func makeNSView(context: Context) -> DropWebView {
        let coordinator = context.coordinator
        let config = WKWebViewConfiguration()
        config.userContentController.add(coordinator, name: "echo")
        let view = DropWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), configuration: config)
        // Clear, so a background image behind the pane shows through the page.
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        view.onDrop = { [weak coordinator] text in coordinator?.type(Data(text.utf8)) }
        coordinator.view = view
        coordinator.apply(appearance)
        coordinator.keyboard = keyboard
        coordinator.focusRequest = focusRequest
        if let page = Self.page { view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent()) }
        if coordinator.show(target), keyboard { Self.focus(view) }
        return view
    }

    func updateNSView(_ view: DropWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.apply(appearance)
        let regained = keyboard && !coordinator.keyboard
        let requested = focusRequest != coordinator.focusRequest
        coordinator.keyboard = keyboard
        coordinator.focusRequest = focusRequest
        if !keyboard {
            Self.unfocus(view)
            coordinator.show(target)
            return
        }
        // Focus moves to the terminal only when it starts showing something new, a modal closes,
        // or the human selects it again, never on a redraw, so a reply being typed in the ledger
        // keeps its focus.
        if coordinator.show(target) || regained || requested { Self.focus(view) }
    }

    static func dismantleNSView(_ view: DropWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "echo")
        coordinator.detach()
    }

    /// The xterm page: in the app's resource bundle (see the Makefile), or SwiftPM's own for `swift run`.
    private static let page: URL? = {
        let bundle = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("HubApp_HubApp.bundle")) }
            ?? Bundle.module
        return bundle.url(forResource: "Terminal", withExtension: nil)?.appendingPathComponent("index.html")
    }()

    private static func unfocus(_ view: DropWebView) {
        guard let window = view.window, window.firstResponder === view else { return }
        window.makeFirstResponder(nil)
        view.evaluateJavaScript("echo.blur()")
    }

    /// Gives the terminal the keyboard once it is in a window.
    private static func focus(_ view: DropWebView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if window.firstResponder !== view { window.makeFirstResponder(view) }
            view.evaluateJavaScript("echo.focus()")
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let client: DaemonClient
        private var target: TerminalTarget?
        private var socket: HubSocket?
        weak var view: DropWebView?
        private var generation = 0
        /// The grid size xterm last reported; 0 until the first layout.
        private var size = (rows: 0, cols: 0)

        private var applied: TerminalAppearance?
        /// Whether the pane last had leave to hold the keyboard.
        var keyboard = true
        /// The last selection's focus request this pane has acted on.
        var focusRequest = 0

        /// Script waiting for the page to load; order is kept, so the look lands before the output.
        private var queued: [String] = []
        private var pageReady = false

        /// Runs `script` in the page, or holds it until the page has loaded.
        private func run(_ script: String) {
            if pageReady { view?.evaluateJavaScript(script) } else { queued.append(script) }
        }

        private func feed(_ bytes: Data) { run("echo.write('\(bytes.base64EncodedString())')") }

        /// Sets the font and colours, only when they changed: re-installing colours redraws everything.
        func apply(_ appearance: TerminalAppearance) {
            guard appearance != applied else { return }
            applied = appearance
            let look: [String: Any] = [
                "fontFamily": "\"\(appearance.fontName)\", Menlo, monospace",
                "fontSize": appearance.fontSize,
                // With an image, the default background is clear and the image shows through from
                // behind the pane; text, coloured cells, and reverse video stay opaque.
                "transparent": appearance.backgroundImage != nil,
                "theme": [
                    "background": appearance.theme.background,
                    "foreground": appearance.theme.foreground,
                    "cursor": appearance.theme.cursor,
                    "selection": appearance.theme.selection,
                    "ansi": appearance.theme.ansi,
                ],
            ]
            guard let json = try? JSONSerialization.data(withJSONObject: look),
                  let text = String(data: json, encoding: .utf8) else { return }
            run("echo.setAppearance(\(text))")
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
            guard let text = note.object as? Data, view?.window != nil else { return }
            type(text)
        }

        /// Types ⌘D's keys into this terminal when it shows a multiplexer in the key window.
        @objc private func typeMuxKeys(_ note: Notification) {
            guard case .shell = target, let keys = note.object as? Data,
                  view?.window?.isKeyWindow == true else { return }
            type(keys)
        }

        /// One queue, so keys reach the daemon in the order they were typed.
        private let writes = DispatchQueue(label: "echo.terminal.writes", qos: .userInteractive)

        /// Sends bytes to whatever the terminal shows.
        func type(_ data: Data) {
            guard let socket else { return }
            writes.async { try? socket.write(data) }
        }

        /// Attaches to `target`, unless already showing it. Returns whether it attached.
        @discardableResult
        func show(_ target: TerminalTarget) -> Bool {
            guard target != self.target else { return false }
            detach()
            self.target = target
            run("echo.reset()")
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
                        DispatchQueue.main.async {
                            guard let self, self.generation == generation else { return }
                            self.feed(chunk)
                        }
                    }
                    DispatchQueue.main.async {
                        guard let self, self.generation == generation else { return }
                        self.feed(Data("\r\n\u{1b}[2m[terminal ended]\u{1b}[0m\r\n".utf8))
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let self, self.generation == generation else { return }
                        self.feed(Data("\u{1b}[2m\(error)\u{1b}[0m\r\n".utf8))
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

        /// Smaller than this is a layout passing through, not a size to give the agent: shrinking
        /// the terminal that far would clip its screen.
        private static let minimumSize = (rows: 8, cols: 40)
        private var pendingResize: DispatchWorkItem?

        private func sizeChanged(cols: Int, rows: Int) {
            guard cols >= Self.minimumSize.cols, rows >= Self.minimumSize.rows else { return }
            size = (rows, cols)
            guard let target, socket != nil else { return }
            // Only the size the layout settles on reaches the daemon.
            pendingResize?.cancel()
            let client = client
            let resize = DispatchWorkItem {
                DispatchQueue.global().async { try? client.resize(target, rows: rows, cols: cols) }
            }
            pendingResize = resize
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: resize)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let kind = body["type"] as? String else { return }
            switch kind {
            case "ready":
                pageReady = true
                queued.forEach { view?.evaluateJavaScript($0) }
                queued = []
                sizeChanged(cols: body["cols"] as? Int ?? 0, rows: body["rows"] as? Int ?? 0)
                if keyboard { view?.evaluateJavaScript("echo.focus()") }
            case "in":
                if let text = body["data"] as? String { type(Data(text.utf8)) }
            case "resize":
                sizeChanged(cols: body["cols"] as? Int ?? 0, rows: body["rows"] as? Int ?? 0)
            case "clipboard":
                if let text = body["text"] as? String {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            case "link":
                if let link = body["url"] as? String, let url = URL(string: link) { NSWorkspace.shared.open(url) }
            default:
                break
            }
        }
    }
}

/// The terminal's web view, taking dropped files and images: their paths are typed at the cursor,
/// as Terminal.app does, so Claude Code attaches an image or reads a file.
final class DropWebView: WKWebView {
    /// Receives the text to type for a drop.
    var onDrop: ((String) -> Void)?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    required init?(coder: NSCoder) { fatalError("DropWebView is built in code") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = Self.paths(from: sender.draggingPasteboard)
        guard !paths.isEmpty else { return false }
        window?.makeFirstResponder(self)
        onDrop?(paths.map(Self.shellQuoted).joined(separator: " ") + " ")
        return true
    }

    /// Backslash-escapes what a shell would split or expand, as Terminal.app does for a dropped path.
    private static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+@%:,="))
        return path.unicodeScalars.map { safe.contains($0) ? String($0) : "\\" + String($0) }.joined()
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
