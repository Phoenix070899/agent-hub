import AppKit
import SwiftUI

/// Moves the window's traffic lights down so they sit centred in Echo's taller top bar, where a
/// unified toolbar would put them. A real toolbar would do this too, but in full screen it draws
/// an opaque strip over the bar. AppKit lays the lights out again on resize, so this repeats.
struct TrafficLightInset: NSViewRepresentable {
    let barHeight: CGFloat

    func makeNSView(context: Context) -> Inset { Inset(barHeight: barHeight) }
    func updateNSView(_ view: Inset, context: Context) { view.place() }

    final class Inset: NSView {
        let barHeight: CGFloat
        private var observers: [NSObjectProtocol] = []

        init(barHeight: CGFloat) {
            self.barHeight = barHeight
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification,
                                              NSWindow.didEnterFullScreenNotification,
                                              NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.place()
                })
            }
            DispatchQueue.main.async { [weak self] in self?.place() }
        }

        /// The lights live in the title bar's container; it grows to the bar's height, and they
        /// centre in it. Full screen shows them in its own strip, so it is left alone.
        func place() {
            let fullScreen = window?.styleMask.contains(.fullScreen) ?? false
            if AppModel.shared.fullScreen != fullScreen { AppModel.shared.fullScreen = fullScreen }
            guard let window, !fullScreen,
                  let close = window.standardWindowButton(.closeButton),
                  let titlebar = close.superview, let container = titlebar.superview else { return }
            container.frame = NSRect(x: container.frame.minX, y: window.frame.height - barHeight,
                                     width: container.frame.width, height: barHeight)
            titlebar.frame = container.bounds
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(kind) else { continue }
                button.setFrameOrigin(NSPoint(x: button.frame.minX, y: ((barHeight - button.frame.height) / 2).rounded()))
            }
        }
    }
}
