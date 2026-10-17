import AppKit
import HubCore
import SwiftTerm
import SwiftUI

/// A daemon-owned terminal drawn with SwiftTerm. Everything SwiftTerm-specific stays in this file,
/// so another renderer (libghostty) can replace it behind the same view.
struct TerminalPane: NSViewRepresentable {
    let target: TerminalTarget
    let client: DaemonClient

    func makeCoordinator() -> Coordinator { Coordinator(client: client) }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.nativeBackgroundColor = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1)
        view.nativeForegroundColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        view.caretColor = NSColor.systemBlue
        view.optionAsMetaKey = true
        view.terminalDelegate = context.coordinator
        context.coordinator.show(target, in: view)
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        context.coordinator.show(target, in: view)
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

        init(client: DaemonClient) { self.client = client }

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
                        if self.size.cols > 10, self.size != (rows, cols) {
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

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            size = (newRows, newCols)
            guard let target, socket != nil, newCols > 10, newRows > 3 else { return }
            let client = client
            DispatchQueue.global().async { try? client.resize(target, rows: newRows, cols: newCols) }
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
