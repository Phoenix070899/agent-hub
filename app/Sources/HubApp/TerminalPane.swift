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
    /// Whether this pane should hold keyboard focus (the app moves focus between panes).
    var isFocused = false
    /// Called when the human clicks into this terminal, so the app knows which pane is active.
    var onFocus: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(client: client) }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        context.coordinator.onFocus = onFocus
        context.coordinator.watchClicks(on: view)
        view.optionAsMetaKey = true
        context.coordinator.apply(appearance, to: view)
        view.terminalDelegate = context.coordinator
        context.coordinator.show(target, in: view)
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        context.coordinator.onFocus = onFocus
        context.coordinator.apply(appearance, to: view)
        context.coordinator.show(target, in: view)
        if isFocused, let window = view.window, window.firstResponder !== view {
            DispatchQueue.main.async { window.makeFirstResponder(view) }
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

        var onFocus: () -> Void = {}
        private var clickMonitor: Any?
        private var applied: TerminalAppearance?

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

        init(client: DaemonClient) { self.client = client }

        deinit {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        }

        /// SwiftTerm does not report focus, so a click inside the view marks this pane active.
        func watchClicks(on view: TerminalView) {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self, weak view] event in
                if let view, event.window === view.window,
                   view.bounds.contains(view.convert(event.locationInWindow, from: nil)) {
                    self?.onFocus()
                }
                return event
            }
        }

        /// Attaches to `target`, unless already showing it.
        func show(_ target: TerminalTarget, in view: TerminalView) {
            guard target != self.target else { return }
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
