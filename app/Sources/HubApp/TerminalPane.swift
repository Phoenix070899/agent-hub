import AppKit
import GhosttyKit
import HubCore
import SwiftUI

/// What a terminal pane runs: the target's own terminal, or the human's multiplexer around it.
enum PaneCommand: Equatable {
    /// `hub attach --echo <target>`, relaying the daemon's terminal.
    case attach
    /// The multiplexer line from the daemon, run by `hub mux` in a login shell; the agent sits in
    /// its first pane, while the multiplexer itself runs right in this pane.
    case mux(String)
}

/// A daemon-owned terminal drawn by libghostty on the GPU. Each pane is a Ghostty surface running
/// `command`; everything renderer-specific stays in this file.
struct TerminalPane: NSViewRepresentable {
    let target: TerminalTarget
    let command: PaneCommand
    let client: DaemonClient
    let appearance: TerminalAppearance
    /// False while a modal is up: the terminal gives up the keyboard, so typing and Escape reach
    /// the modal rather than the agent.
    let keyboard: Bool
    /// Changes when the human selects what this pane shows, even if it already shows it.
    let focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(client: client) }

    func makeNSView(context: Context) -> GhosttyView {
        let coordinator = context.coordinator
        let view = GhosttyView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        view.onDrop = { [weak coordinator] text in coordinator?.type(text) }
        view.onSettled = { [weak coordinator] in coordinator?.settled() }
        view.onExit = { [weak coordinator] seconds in MainActor.assumeIsolated { coordinator?.exited(after: seconds) } }
        coordinator.view = view
        GhosttyRuntime.shared.apply(appearance)
        coordinator.keyboard = keyboard
        coordinator.focusRequest = focusRequest
        if coordinator.show(target, command), keyboard { Self.focus(view) }
        return view
    }

    func updateNSView(_ view: GhosttyView, context: Context) {
        let coordinator = context.coordinator
        GhosttyRuntime.shared.apply(appearance)
        let regained = keyboard && !coordinator.keyboard
        let requested = focusRequest != coordinator.focusRequest
        coordinator.keyboard = keyboard
        coordinator.focusRequest = focusRequest
        if !keyboard {
            Self.unfocus(view)
            coordinator.show(target, command)
            return
        }
        // Focus moves to the terminal only when it starts showing something new, a modal closes,
        // or the human selects it again, never on a redraw, so a reply being typed in the ledger
        // keeps its focus.
        if coordinator.show(target, command) || regained || requested { Self.focus(view) }
    }

    static func dismantleNSView(_ view: GhosttyView, coordinator: Coordinator) {
        view.stop()
    }

    private static func unfocus(_ view: GhosttyView) {
        guard let window = view.window, window.firstResponder === view else { return }
        window.makeFirstResponder(nil)
    }

    /// Gives the terminal the keyboard once it is in a window.
    private static func focus(_ view: GhosttyView) {
        DispatchQueue.main.async {
            guard let window = view.window, window.firstResponder !== view else { return }
            window.makeFirstResponder(view)
        }
    }

    final class Coordinator: NSObject {
        let client: DaemonClient
        private(set) var target: TerminalTarget?
        private var command = PaneCommand.attach
        weak var view: GhosttyView?
        /// Whether the pane last had leave to hold the keyboard.
        var keyboard = true
        /// The last selection's focus request this pane has acted on.
        var focusRequest = 0
        private var generation = 0

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
            type(String(decoding: text, as: UTF8.self))
        }

        /// Types ⌘D's keys into this terminal when it shows a multiplexer in the key window.
        @objc private func typeMuxKeys(_ note: Notification) {
            guard case .mux = command, let keys = note.object as? Data,
                  view?.window?.isKeyWindow == true else { return }
            type(String(decoding: keys, as: UTF8.self))
        }

        /// One queue, so what Echo types reaches the daemon in order.
        private let writes = DispatchQueue(label: "echo.terminal.writes", qos: .userInteractive)

        /// Sends bytes exactly as given (a bracketed paste stays one paste): to the multiplexer
        /// through this pane's own terminal, which hands them to its focused pane; else straight to
        /// the terminal the daemon owns.
        func type(_ text: String) {
            guard let target else { return }
            if case .mux = command { return view?.typeRaw(text) ?? () }
            let client = client
            writes.async { try? client.write(target, text: text) }
        }

        /// The multiplexer exited: the app replaces it, or falls back to the plain terminal.
        @MainActor func exited(after seconds: Double) {
            guard case .mux = command, let target else { return }
            AppModel.shared.muxExited(target, after: seconds)
        }

        /// Shows `target` through `command`, unless already showing it so. Returns whether it
        /// changed. It starts at once when the pane's size has settled, else when it does.
        @discardableResult
        func show(_ target: TerminalTarget, _ command: PaneCommand) -> Bool {
            guard target != self.target || command != self.command else { return false }
            self.target = target
            self.command = command
            generation += 1
            view?.stop()
            if view?.isSettled == true { start() }
            return true
        }

        /// The pane's first layout settled: a terminal that waited for it attaches now.
        func settled() {
            if view?.surface == nil { start() }
        }

        private static var hub: String?

        /// Starts the surface for the current target, finding `hub` first if need be.
        private func start() {
            guard let target, let view, view.surface == nil else { return }
            if let hub = Self.hub {
                switch command {
                case .attach: view.start(command: Self.command(hub, "attach --echo \(target.label)"))
                case .mux(let line): view.start(command: Self.command(hub, "mux"), env: ["HUB_MUX": line])
                }
                return
            }
            let generation = generation
            let client = client
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let found = Result { try AppModel.ensureDaemon(client); return try client.hubExecutable() }
                DispatchQueue.main.async {
                    guard let self, self.generation == generation else { return }
                    switch found {
                    case .success(let hub):
                        Self.hub = hub
                        self.start()
                    case .failure(let error):
                        self.view?.show(problem: "\(error)")
                    }
                }
            }
        }

        /// `direct:` runs `hub` as given, with no shell or login(1) in between (see ghostty.patch);
        /// a path with a space, which that form cannot hold, goes through the shell instead.
        private static func command(_ hub: String, _ args: String) -> String {
            guard hub.contains(" ") else { return "direct:\(hub) \(args)" }
            return "'" + hub.replacingOccurrences(of: "'", with: "'\\''") + "' " + args
        }
    }
}

/// libghostty's app: one for Echo, holding the config every surface draws with.
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()
    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private(set) var applied: TerminalAppearance?

    private init() {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else { return }
        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in DispatchQueue.main.async { GhosttyRuntime.shared.tick() } },
            action_cb: { _, target, action in GhosttyRuntime.perform(action, on: target) },
            read_clipboard_cb: { userdata, _, state, mimes, count, _ in
                GhosttyRuntime.readClipboard(userdata, state: state, mimes: mimes, count: count)
            },
            confirm_read_clipboard_cb: { userdata, _, state, _ in
                // `clipboard-read = deny`: programs never read the clipboard.
                guard let view = GhosttyView.from(userdata), let surface = view.surface else { return }
                ghostty_surface_deny_clipboard_request(surface, state)
            },
            write_clipboard_cb: { _, location, content, count, _ in
                GhosttyRuntime.writeClipboard(location, content: content, count: count)
            },
            close_surface_cb: { _, _ in }
        )
        let config = Self.makeConfig(.orca)
        app = ghostty_app_new(&runtime, config)
        self.config = config
        applied = .orca
        if let app { ghostty_app_set_focus(app, NSApp.isActive) }
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, true) }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, false) }
        }
        center.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { _ in
            if let app = GhosttyRuntime.shared.app { ghostty_app_keyboard_changed(app) }
        }
    }

    private func tick() {
        if let app { ghostty_app_tick(app) }
    }

    /// Sets the font and colours of every terminal, only when they changed.
    func apply(_ appearance: TerminalAppearance) {
        guard appearance != applied, let app else { return }
        applied = appearance
        let next = Self.makeConfig(appearance)
        ghostty_app_update_config(app, next)
        if let config { ghostty_config_free(config) }
        config = next
    }

    private static func makeConfig(_ appearance: TerminalAppearance) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("echo-ghostty-\(getpid()).conf")
        try? appearance.ghosttyConfig.write(to: file, atomically: true, encoding: .utf8)
        ghostty_config_load_file(config, file.path)
        try? FileManager.default.removeItem(at: file)
        ghostty_config_finalize(config)
        return config
    }

    private static func perform(_ action: ghostty_action_s, on target: ghostty_target_s) -> Bool {
        if action.tag == GHOSTTY_ACTION_OPEN_URL {
            let open = action.action.open_url
            guard let pointer = open.url else { return false }
            let text = String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(open.len)), as: UTF8.self)
            guard let url = URL(string: text) else { return false }
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            return true
        }
        guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface,
              let view = GhosttyView.from(ghostty_surface_userdata(surface)) else { return false }
        switch action.tag {
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            let seconds = Double(action.action.child_exited.timetime_ms) / 1000
            DispatchQueue.main.async { view.onExit?(seconds) }
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            view.mouseShape(action.action.mouse_shape)
        case GHOSTTY_ACTION_START_SEARCH:
            let needle = action.action.start_search.needle.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async { view.find.open(needle) }
        case GHOSTTY_ACTION_END_SEARCH:
            DispatchQueue.main.async { view.find.close() }
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let total = action.action.search_total.total
            DispatchQueue.main.async { view.find.total = total }
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let selected = action.action.search_selected.selected
            DispatchQueue.main.async { view.find.selected = selected }
        default:
            return false
        }
        return true
    }

    private static func readClipboard(_ userdata: UnsafeMutableRawPointer?, state: UnsafeMutableRawPointer?,
                                      mimes: UnsafePointer<UnsafePointer<CChar>?>?, count: Int) -> ghostty_clipboard_read_result_e
    {
        guard let view = GhosttyView.from(userdata), let surface = view.surface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        let wanted = (0..<count).compactMap { mimes?[$0].map { String(cString: $0) } }
        guard wanted.contains(where: { $0.hasPrefix("text/plain") }),
              let text = NSPasteboard.general.string(forType: .string) else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        let data = Array(text.utf8)
        "text/plain".withCString { mime in
            data.withUnsafeBufferPointer { bytes in
                bytes.baseAddress!.withMemoryRebound(to: CChar.self, capacity: max(data.count, 1)) { chars in
                    var content = ghostty_clipboard_content_s(mime: mime, data: chars, len: data.count)
                    withUnsafePointer(to: &content) { contents in
                        var complete = ghostty_clipboard_complete_s(
                            contents: contents, contents_len: 1, available: nil, available_len: 0,
                            confirmed: false, remember: false)
                        ghostty_surface_complete_clipboard_request(surface, &complete, state)
                    }
                }
            }
        }
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// Copies, and what programs copy (OSC 52), land on the general pasteboard.
    private static func writeClipboard(_ location: ghostty_clipboard_e, content: UnsafePointer<ghostty_clipboard_content_s>?, count: Int) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD, let content else { return }
        for i in 0..<count {
            let item = content[i]
            guard let mime = item.mime, String(cString: mime).hasPrefix("text/plain"), let data = item.data else { continue }
            let text = String(decoding: UnsafeRawBufferPointer(start: data, count: item.len), as: UTF8.self)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return
        }
    }
}

/// The view a Ghostty surface draws into, and the keyboard, mouse, and input-method events it
/// hands that surface, after Ghostty's own macOS view.
final class GhosttyView: NSView, NSTextInputClient {
    private(set) var surface: ghostty_surface_t?
    /// Receives the text to type for dropped files.
    var onDrop: ((String) -> Void)?
    /// Called once, when the first layout has held still for a moment.
    var onSettled: (() -> Void)?
    /// Called when the surface's process exits, with how long it ran in seconds.
    var onExit: ((Double) -> Void)?
    /// The layout has settled at least once, so the frame is the pane's real size and not a
    /// first guess; a terminal starts only then, or the daemon would redraw it at the wrong size.
    private(set) var isSettled = false
    private var settle: DispatchWorkItem?
    let find = FindBar()
    private var problem: NSTextField?

    /// Text the input method is composing, shown by the surface until committed.
    private var markedText = NSMutableAttributedString()
    /// Set while `keyDown` runs `interpretKeyEvents`, collecting the text it commits.
    private var keyTextAccumulator: [String]?
    private var cursorShape: NSCursor = .iBeam

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff])
        find.view = self
        addSubview(find)
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) { fatalError("GhosttyView is built in code") }

    deinit { stop() }

    static func from(_ userdata: UnsafeMutableRawPointer?) -> GhosttyView? {
        userdata.map { Unmanaged<GhosttyView>.fromOpaque($0).takeUnretainedValue() }
    }

    /// Runs `command` in a new surface sized to this view, with `env` added to Echo's own.
    func start(command: String, env extra: [String: String] = [:]) {
        guard surface == nil, let app = GhosttyRuntime.shared.app else {
            if GhosttyRuntime.shared.app == nil { show(problem: "libghostty could not start, so no terminal can be drawn.") }
            return
        }
        problem?.removeFromSuperview()
        problem = nil
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        var env = extra
        if let state = ProcessInfo.processInfo.environment["HUB_STATE"] { env["HUB_STATE"] = state }
        let strings = env.flatMap { [strdup($0.key), strdup($0.value)] }
        defer { strings.forEach { free($0) } }
        var vars = stride(from: 0, to: strings.count, by: 2).map {
            ghostty_env_var_s(key: UnsafePointer(strings[$0]), value: UnsafePointer(strings[$0 + 1]))
        }
        surface = command.withCString { command in
            config.command = command
            return vars.withUnsafeMutableBufferPointer { vars in
                config.env_vars = vars.baseAddress
                config.env_var_count = vars.count
                return ghostty_surface_new(app, &config)
            }
        }
        guard surface != nil else { return show(problem: "libghostty could not open a terminal.") }
        syncScale()
        syncDisplay()
        syncOcclusion()
        if let surface { ghostty_surface_set_focus(surface, window?.firstResponder === self) }
        addSubview(find, positioned: .above, relativeTo: nil)
    }

    /// Writes `text` to this surface's own terminal as is, as if typed byte for byte.
    func typeRaw(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        // Ghostty's `text:` action takes Zig string escapes, so every byte goes as `\xNN`.
        let action = "text:" + text.utf8.map { String(format: "\\x%02x", $0) }.joined()
        _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
    }

    /// Ends the surface, and with it the `hub attach` inside; the daemon's terminal keeps running.
    func stop() {
        find.close()
        guard let surface else { return }
        self.surface = nil
        ghostty_surface_free(surface)
    }

    /// A line in place of the terminal, when there is none to draw.
    func show(problem text: String) {
        problem?.removeFromSuperview()
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.frame = bounds.insetBy(dx: 8, dy: 8)
        label.autoresizingMask = [.width, .height]
        addSubview(label)
        problem = label
    }

    // MARK: Size

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        syncSize()
        find.place(in: bounds)
        guard !isSettled, size.width > 0, size.height > 0 else { return }
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isSettled else { return }
            self.isSettled = true
            self.onSettled?()
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func syncSize() {
        guard let surface else { return }
        let pixels = convertToBacking(bounds.size)
        ghostty_surface_set_size(surface, UInt32(max(pixels.width, 1)), UInt32(max(pixels.height, 1)))
    }

    private func syncScale() {
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        guard let surface, bounds.width > 0, bounds.height > 0 else { return syncSize() }
        let pixels = convertToBacking(bounds)
        ghostty_surface_set_content_scale(surface, pixels.width / bounds.width, pixels.height / bounds.height)
        syncSize()
    }

    private func syncDisplay() {
        guard let surface, let number = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        ghostty_surface_set_display_id(surface, number.uint32Value)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncScale()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        guard let window else { return }
        center.addObserver(self, selector: #selector(screenChanged), name: NSWindow.didChangeScreenNotification, object: window)
        center.addObserver(self, selector: #selector(syncOcclusion), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        syncScale()
        syncDisplay()
        syncOcclusion()
    }

    /// The surface draws only while its window can be seen, and redraws as soon as it can again.
    @objc private func syncOcclusion() {
        guard let surface, let window else { return }
        ghostty_surface_set_occlusion(surface, window.occlusionState.contains(.visible))
    }

    @objc private func screenChanged() {
        syncScale()
        syncDisplay()
    }

    // MARK: Focus

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface { ghostty_surface_set_focus(surface, true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface { ghostty_surface_set_focus(surface, false) }
        return result
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else { return interpretKeyEvents([event]) }
        // Option as Alt and the like: the mods the surface wants the text translated with.
        let wanted = Self.flags(ghostty_surface_key_translation_mods(surface, Self.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if wanted.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        // The same event when nothing changes: Korean input needs that.
        let translation = translationMods == event.modifierFlags ? event : NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: event.characters(byApplyingModifiers: translationMods) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let markedBefore = markedText.length > 0
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        interpretKeyEvents([translation])
        syncPreedit(clearIfNeeded: markedBefore)
        let composing = markedText.length > 0 || markedBefore

        if let committed = keyTextAccumulator, !committed.isEmpty {
            for text in committed where !Self.isControl(text) || !composing {
                key(action, event: event, translation: translation, text: text)
            }
        } else if !(composing && Self.isControl(event.characters)) {
            key(action, event: event, translation: translation, text: Self.characters(of: translation), composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        key(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        guard !hasMarkedText() else { return }
        let pressed = Self.mods(event.modifierFlags).rawValue & mod != 0
        key(pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE, event: event)
    }

    /// ⌘ keys go to the terminal only when they are one of its bindings (copy, paste, find...);
    /// every other one reaches Echo's menus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let surface, window?.firstResponder === self else { return false }
        var flags = ghostty_binding_flags_e(0)
        var ev = Self.keyEvent(GHOSTTY_ACTION_PRESS, event)
        let binding = (event.characters ?? "").withCString { text in
            ev.text = text
            return ghostty_surface_key_is_binding(surface, ev, &flags)
        }
        if binding {
            keyDown(with: event)
            return true
        }
        // Control-Return and Control-/ reach the terminal rather than AppKit's beep.
        if event.modifierFlags.contains(.control), ["\r", "/"].contains(event.charactersIgnoringModifiers) {
            keyDown(with: event)
            return true
        }
        return false
    }

    /// Commands `interpretKeyEvents` has no use for: the key itself already went to the surface.
    override func doCommand(by selector: Selector) {}

    private func key(_ action: ghostty_input_action_e, event: NSEvent, translation: NSEvent? = nil,
                     text: String? = nil, composing: Bool = false)
    {
        guard let surface else { return }
        var ev = Self.keyEvent(action, event, translationMods: translation?.modifierFlags)
        ev.composing = composing
        if let text, !text.isEmpty, !Self.isControl(text) {
            text.withCString { pointer in
                ev.text = pointer
                _ = ghostty_surface_key(surface, ev)
            }
        } else {
            _ = ghostty_surface_key(surface, ev)
        }
    }

    private static func keyEvent(_ action: ghostty_input_action_e, _ event: NSEvent,
                                 translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s
    {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(event.keyCode)
        ev.mods = mods(event.modifierFlags)
        // Control and Command never take part in turning a key into text.
        ev.consumed_mods = mods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        if event.type == .keyDown || event.type == .keyUp,
           let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first {
            ev.unshifted_codepoint = scalar.value
        }
        return ev
    }

    /// The key's text, without control characters (the surface encodes those itself) or the
    /// private-use characters AppKit gives function keys.
    private static func characters(of event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 { return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return characters
    }

    private static func isControl(_ text: String?) -> Bool {
        guard let first = text?.unicodeScalars.first else { return false }
        return first.value < 0x20
    }

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }

    private static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    // MARK: Input method

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
            return
        }
        // Dictation and the like, outside a key press: typed, never pasted.
        guard let surface, !text.isEmpty else { return }
        var ev = ghostty_input_key_s()
        ev.action = GHOSTTY_ACTION_PRESS
        text.withCString { pointer in
            ev.text = pointer
            _ = ghostty_surface_key(surface, ev)
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = NSMutableAttributedString(string: (string as? NSAttributedString)?.string ?? (string as? String) ?? "")
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText = NSMutableAttributedString()
        syncPreedit()
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let text = markedText.string
            text.withCString { ghostty_surface_preedit(surface, $0, UInt(text.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }
    func markedRange() -> NSRange { markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange() }
    func selectedRange() -> NSRange { NSRange() }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    /// Where the input method's candidate window goes: at the cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return window?.convertToScreen(convert(bounds, to: nil)) ?? .zero }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let rect = NSRect(x: x, y: bounds.height - y, width: range.length == 0 ? 0 : width, height: height)
        let inWindow = convert(rect, to: nil)
        return window?.convertToScreen(inWindow) ?? inWindow
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
                                       owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event)
    }

    override func mouseUp(with event: NSEvent) {
        button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event)
        if let surface { ghostty_surface_mouse_pressure(surface, 0, 0) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if !button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event) { super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if !button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event) { super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, event) }
    }

    @discardableResult
    private func button(_ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, _ event: NSEvent) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_mouse_button(surface, state, button, Self.mods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, Self.mods(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        // While dragging, the drag keeps reporting where the mouse is.
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            x *= 2
            y *= 2
        }
        // Bit 0: a trackpad's precise deltas; bits 1 to 3: the momentum phase.
        let momentum: Int32 = switch event.momentumPhase {
        case .began: 1
        case .stationary: 2
        case .changed: 3
        case .ended: 4
        case .cancelled: 5
        case .mayBegin: 6
        default: 0
        }
        ghostty_surface_mouse_scroll(surface, x, y, (precise ? 1 : 0) | momentum << 1)
    }

    override func pressureChange(with event: NSEvent) {
        if let surface { ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure)) }
    }

    func mouseShape(_ shape: ghostty_action_mouse_shape_e) {
        let cursor: NSCursor = switch shape {
        case GHOSTTY_MOUSE_SHAPE_POINTER: .pointingHand
        case GHOSTTY_MOUSE_SHAPE_TEXT: .iBeam
        default: .arrow
        }
        DispatchQueue.main.async {
            self.cursorShape = cursor
            self.window?.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursorShape)
    }

    // MARK: Drops

    /// Dropped files and images type their paths at the cursor, as Terminal.app does, so Claude
    /// Code attaches an image or reads a file.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = Self.paths(from: sender.draggingPasteboard)
        guard !paths.isEmpty else { return false }
        window?.makeFirstResponder(self)
        onDrop?(droppedPaths(paths))
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

/// ⌘F's find field over the terminal's top right; the surface finds and highlights the matches.
final class FindBar: NSView, NSTextFieldDelegate {
    weak var view: GhosttyView?
    private let field = NSTextField()
    private let count = NSTextField(labelWithString: "")
    var total: Int = -1 { didSet { updateCount() } }
    var selected: Int = -1 { didSet { updateCount() } }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 30))
        isHidden = true
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        field.placeholderString = "Find"
        field.font = .systemFont(ofSize: 12)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.alignment = .right
        field.frame = NSRect(x: 8, y: 7, width: 180, height: 16)
        count.frame = NSRect(x: 190, y: 7, width: 62, height: 16)
        addSubview(field)
        addSubview(count)
    }

    required init?(coder: NSCoder) { fatalError("FindBar is built in code") }

    func place(in bounds: NSRect) {
        setFrameOrigin(NSPoint(x: bounds.maxX - frame.width - 14, y: bounds.maxY - frame.height - 8))
    }

    func open(_ needle: String) {
        // The theme's own colours, as the terminal around it.
        let theme = GhosttyRuntime.shared.applied?.theme ?? TerminalTheme.ayuDark
        layer?.backgroundColor = Self.color(theme.background).cgColor
        layer?.borderColor = Self.color(theme.selection).cgColor
        field.textColor = Self.color(theme.foreground)
        count.textColor = Self.color(theme.foreground).withAlphaComponent(0.6)
        if !needle.isEmpty { field.stringValue = needle }
        isHidden = false
        window?.makeFirstResponder(field)
        field.selectText(nil)
        search(field.stringValue)
    }

    func close() {
        guard !isHidden else { return }
        isHidden = true
        total = -1
        selected = -1
        if let view, window?.firstResponder === field.currentEditor() { window?.makeFirstResponder(view) }
    }

    private func updateCount() {
        count.stringValue = total < 0 ? "" : total == 0 ? "No matches" : "\(max(selected, 0) + 1) of \(total)"
    }

    private static func color(_ hex: String) -> NSColor {
        guard let c = TerminalTheme.rgb(hex) else { return .labelColor }
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    }

    private func search(_ text: String) {
        binding("search:\(text)")
    }

    private func binding(_ action: String) {
        guard let surface = view?.surface else { return }
        _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
    }

    func controlTextDidChange(_ note: Notification) {
        search(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let back = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            binding(back ? "navigate_search:previous" : "navigate_search:next")
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            binding("end_search")
            close()
            return true
        default:
            return false
        }
    }
}
