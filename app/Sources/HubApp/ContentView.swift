import HubCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
        } detail: {
            Detail()
        }
        .toolbar { SessionToolbar() }
        .navigationTitle(model.selectedRepo.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Hub")
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
    }
}

/// Dashboard colors, the same as the terminal band: yellow needs you, blue running, green done, red failed.
extension WorkerState {
    var color: Color {
        switch self {
        case .needsYou: return .yellow
        case .running: return .blue
        case .done: return .green
        case .failed: return .red
        }
    }

    var symbol: String {
        switch self {
        case .needsYou: return "exclamationmark.circle.fill"
        case .running: return "circle.dotted.circle"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .needsYou: return "Needs you"
        case .running: return "Running"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }
}

/// One card per Hub Session: its Orchestrator, with its Workers folded inside.
struct Sidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            if model.sessions.isEmpty {
                Text("No sessions yet")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.sessions) { session in
                SessionCard(session: session, snapshot: model.snapshots[session.repo])
                    .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { model.chooseSession() } label: { Label("New Session", systemImage: "plus") }
                    .buttonStyle(.glass)
                Spacer()
                if !model.connected {
                    Label("Reconnecting", systemImage: "bolt.horizontal.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
}

struct SessionCard: View {
    @EnvironmentObject private var model: AppModel
    let session: SessionInfo
    let snapshot: Snapshot?

    private var workers: [WorkerRow] { snapshot?.workers ?? [] }
    private var live: Bool { snapshot?.orchestrator.live ?? session.live }
    private var isCollapsed: Bool { model.collapsed.contains(session.repo) }
    private var orchestratorSelected: Bool { model.selection == .orchestrator(repo: session.repo) }
    private var cardSelected: Bool { model.selection?.repo == session.repo }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !isCollapsed && !workers.isEmpty {
                Divider().padding(.horizontal, 10)
                VStack(spacing: 2) {
                    ForEach(workers) { worker in
                        let selected = model.selection == .worker(repo: session.repo, id: worker.id)
                        WorkerRowView(worker: worker)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selected ? Color.accentColor.opacity(0.25) : Color.clear)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { model.select(.worker(repo: session.repo, id: worker.id)) }
                    }
                }
                .padding(6)
            }
        }
        .glassEffect(
            cardSelected ? .regular.tint(Color.accentColor.opacity(0.22)).interactive() : .regular.interactive(),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .opacity(live || !workers.isEmpty ? 1 : 0.6)
        .contextMenu {
            if live {
                Button("Stop Orchestrator") { model.stopOrchestrator(repo: session.repo) }
            } else {
                Button("Start Orchestrator") { model.open(repo: session.repo) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(live ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(live ? "Live" : "Stopped")
                        .foregroundStyle(.secondary)
                    ForEach([WorkerState.running, .done, .failed], id: \.self) { state in
                        let count = workers.filter { $0.state == state }.count
                        if count > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: state.symbol).imageScale(.small)
                                Text("\(count)").monospacedDigit()
                            }
                            .foregroundStyle(state.color)
                            .help("\(count) \(state.label.lowercased())")
                        }
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            let needs = snapshot?.needsYouCount ?? 0
            if needs > 0 {
                Text("\(needs)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.yellow))
                    .help("\(needs) need you")
            }
            Circle()
                .fill(live ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
                .help(live ? "Orchestrator live" : "Orchestrator stopped")
            if !workers.isEmpty {
                Button { withAnimation(.easeInOut(duration: 0.15)) { model.toggleCollapsed(session.repo) } } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "Show Workers" : "Hide Workers")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(orchestratorSelected ? Color.accentColor.opacity(0.25) : Color.clear)
                .padding(3)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.select(.orchestrator(repo: session.repo)) }
    }
}

struct WorkerRowView: View {
    let worker: WorkerRow

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: worker.state.symbol)
                .foregroundStyle(worker.state.color)
                .symbolEffect(.pulse, isActive: worker.state == .running)
                .frame(width: 14)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(worker.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 5) {
                    Text(worker.profile).fontWeight(.medium)
                    Text("·")
                    Text(worker.branch ?? worker.place).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(formatAge(worker.quietSeconds)).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .help("\(worker.id) · \(worker.state.label)")
    }
}

struct Detail: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                ErrorBanner(text: error)
            }
            let needs = model.selectedSnapshot?.needs ?? []
            if !needs.isEmpty {
                NeedsInbox(needs: needs)
                Divider()
            }
            if let repo = model.selectedRepo {
                PaneTree(layout: model.layout(for: repo), repo: repo)
            } else {
                ContentUnavailableView {
                    Label("No Hub Session", systemImage: "folder.badge.plus")
                } description: {
                    Text("Open a git repo to start its Orchestrator.")
                } actions: {
                    Button("New Session…") { model.chooseSession() }
                        .buttonStyle(.glassProminent)
                }
            }
            UsageFooter(usage: model.usage)
        }
        .background(TerminalTheme.color(model.appearance.theme.background))
    }
}

/// A settled Worker whose terminal is closed: its Final Report, if it sent one.
struct FinishedWorker: View {
    let worker: WorkerRow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(worker.state.label, systemImage: worker.state.symbol)
                    .foregroundStyle(worker.state.color)
                    .font(.headline)
                Text("\(worker.id) · \(worker.profile) · \(worker.title)")
                    .foregroundStyle(.secondary)
                Text(worker.finalReport ?? "No Final Report.")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }
}

struct ErrorBanner: View {
    @EnvironmentObject private var model: AppModel
    let text: String

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(text).lineLimit(2)
            Spacer()
            Button { model.error = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.12))
    }
}

struct SessionToolbar: ToolbarContent {
    @EnvironmentObject private var model: AppModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if let repo = model.selectedRepo, model.snapshots[repo]?.orchestrator.live == true {
                Button { model.stopOrchestrator(repo: repo) } label: {
                    Label("Stop Orchestrator", systemImage: "stop.circle")
                }
                .help("Stop this Orchestrator; its Workers keep running")
            }
        }
    }
}

/// The Claude account's plan limits at the foot of the window. Click to re-read them.
struct UsageFooter: View {
    @EnvironmentObject private var model: AppModel
    let usage: Usage?

    var body: some View {
        HStack(spacing: 20) {
            if let usage, !usage.limits.isEmpty {
                ForEach(usage.limits) { limit in
                    LimitGauge(limit: limit)
                }
            } else if let error = usage?.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Label("Reading Claude usage…", systemImage: "gauge.with.dots.needle.0percent")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { model.refreshUsage() } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(usage?.refreshing == true ? 180 : 0))
                    .animation(.easeInOut(duration: 0.4), value: usage?.refreshing)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(updatedHelp)
        }
        .font(.callout)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 16)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var updatedHelp: String {
        guard let at = usage?.updatedAt else { return "Refresh Claude usage" }
        let date = Date(timeIntervalSince1970: TimeInterval(at))
        return "Claude account usage, updated \(date.formatted(.relative(presentation: .named))). Click to refresh."
    }
}

struct LimitGauge: View {
    let limit: Usage.Limit

    private var fraction: Double { min(max(Double(limit.percent) / 100, 0), 1) }

    /// "Oct 17 at 4:50pm" reads "4:50pm" today, else "Oct 23".
    private var shortReset: String? {
        guard let resets = limit.resets else { return nil }
        let parts = resets.components(separatedBy: " at ")
        guard parts.count == 2 else { return resets }
        return parts[0] == Self.today() ? parts[1] : parts[0]
    }

    /// Today as `/usage` writes dates, "Oct 17", whatever the Mac's locale.
    private static func today() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: Date())
    }
    private var tint: Color { fraction >= 0.9 ? .red : fraction >= 0.7 ? .orange : .accentColor }

    var body: some View {
        HStack(spacing: 7) {
            Text(limit.name).foregroundStyle(.secondary)
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(tint)
                .frame(width: 64)
            Text("\(limit.percent)%")
                .monospacedDigit()
                .foregroundStyle(fraction >= 0.7 ? tint : .primary)
            if let reset = shortReset {
                Text(reset).foregroundStyle(.tertiary)
            }
        }
        .help(limit.resets.map { "\(limit.name): \(limit.percent)% used, resets \($0)" } ?? "\(limit.name): \(limit.percent)% used")
    }
}

extension TerminalTheme {
    static func color(_ hex: String) -> Color {
        guard let c = rgb(hex) else { return .clear }
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue)
    }
}

/// Where a split's divider sits, as a fraction of its length.
final class SplitRatio: ObservableObject {
    @Published var value: CGFloat = 0.5
    var dragStart: CGFloat?
}

/// Two panes split evenly, with a divider to drag.
struct SplitBox<First: View, Second: View>: View {
    let axis: SplitAxis
    @ViewBuilder let first: () -> First
    @ViewBuilder let second: () -> Second
    @StateObject private var ratio = SplitRatio()
    private let divider: CGFloat = 1
    private let minimum: CGFloat = 120

    var body: some View {
        GeometryReader { geometry in
            let length = axis == .horizontal ? geometry.size.width : geometry.size.height
            let usable = max(length - divider, 0)
            let firstLength = min(max(usable * ratio.value, min(minimum, usable / 2)), usable - min(minimum, usable / 2))
            let layout = axis == .horizontal
                ? AnyLayout(HStackLayout(spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))
            layout {
                first()
                    .frame(
                        width: axis == .horizontal ? firstLength : nil,
                        height: axis == .vertical ? firstLength : nil
                    )
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: axis == .horizontal ? divider : nil, height: axis == .vertical ? divider : nil)
                    .overlay {
                        // A wider grab area than the 1-point line.
                        Color.clear
                            .frame(width: axis == .horizontal ? 8 : nil, height: axis == .vertical ? 8 : nil)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                let cursor: NSCursor = axis == .horizontal ? .resizeLeftRight : .resizeUpDown
                                if inside { cursor.push() } else { NSCursor.pop() }
                            }
                            .gesture(
                                DragGesture(minimumDistance: 1)
                                    .onChanged { drag in
                                        let start = ratio.dragStart ?? ratio.value
                                        ratio.dragStart = start
                                        let moved = axis == .horizontal ? drag.translation.width : drag.translation.height
                                        ratio.value = min(max(start + moved / max(usable, 1), 0.1), 0.9)
                                    }
                                    .onEnded { _ in ratio.dragStart = nil }
                            )
                    }
                second()
            }
        }
    }
}

/// A session's panes: split right or down, each pane with its own tabs.
struct PaneTree: View {
    let layout: PaneLayout
    let repo: String

    var body: some View {
        switch layout {
        case .group(let group):
            PaneView(group: group, repo: repo)
        case .split(let axis, let first, let second):
            SplitBox(axis: axis) {
                PaneTree(layout: first, repo: repo)
            } second: {
                PaneTree(layout: second, repo: repo)
            }
        }
    }
}

/// One pane: its tab bar, then the terminal of the tab showing.
struct PaneView: View {
    @EnvironmentObject private var model: AppModel
    let group: TabGroup
    let repo: String

    private var isFocused: Bool { model.focusedGroup(in: repo) == group.id }

    var body: some View {
        VStack(spacing: 0) {
            PaneTabBar(group: group, repo: repo, isFocused: isFocused)
            content
                .frame(minWidth: 120, minHeight: 60)
        }
        .overlay {
            let split = model.layout(for: repo).groups.count > 1
            Rectangle()
                .strokeBorder(Color.accentColor.opacity(split && isFocused ? 0.7 : 0), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var content: some View {
        let snapshot = model.snapshots[repo]
        let focus = { model.focus(group: group.id, in: repo) }
        switch group.activeTab {
        case .orchestrator?:
            if snapshot?.orchestrator.live == true {
                TerminalPane(target: .orchestrator(repo: repo), client: model.client, appearance: model.appearance,
                             isFocused: isFocused, onFocus: focus)
            } else {
                ContentUnavailableView {
                    Label("Orchestrator stopped", systemImage: "sparkles")
                } description: {
                    Text("Its Workers keep running. Starting it resumes its conversation.")
                } actions: {
                    Button("Start Orchestrator") { model.open(repo: repo) }
                        .buttonStyle(.glassProminent)
                }
            }
        case .worker(let id)?:
            if let worker = snapshot?.workers.first(where: { $0.id == id }) {
                if worker.live, let number = worker.number {
                    TerminalPane(target: .worker(id: number), client: model.client, appearance: model.appearance,
                                 isFocused: isFocused, onFocus: focus)
                } else {
                    FinishedWorker(worker: worker)
                }
            } else {
                ContentUnavailableView("\(id) is gone", systemImage: "questionmark.square.dashed")
            }
        case .shell(let id)?:
            TerminalPane(target: .shell(id: id), client: model.client, appearance: model.appearance,
                         isFocused: isFocused, onFocus: focus)
        case nil:
            Color.clear
        }
    }
}

/// The tabs of one pane, and only that pane.
struct PaneTabBar: View {
    @EnvironmentObject private var model: AppModel
    let group: TabGroup
    let repo: String
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(Array(group.tabs.enumerated()), id: \.element) { index, tab in
                        let look = self.look(of: tab)
                        TabButton(
                            title: look.title,
                            symbol: look.symbol,
                            tint: look.tint,
                            selected: index == group.active,
                            emphasized: isFocused,
                            onClose: { model.close(tab, in: repo) }
                        ) {
                            model.activate(index, in: group.id, repo: repo)
                        }
                        .help(look.help)
                    }
                }
                .padding(.horizontal, 6)
                }
            }
            Button {
                model.focus(group: group.id, in: repo)
                model.newShellTab()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .padding(.trailing, 6)
            .help("New shell tab (⌘T)")
        }
        .frame(height: 36)
    }

    private func look(of tab: TabRef) -> (title: String, symbol: String, tint: Color, help: String) {
        let snapshot = model.snapshots[repo]
        switch tab {
        case .orchestrator:
            let live = snapshot?.orchestrator.live == true
            return ("Orchestrator", "sparkles", live ? .accentColor : .secondary, "The Orchestrator")
        case .worker(let id):
            let worker = snapshot?.workers.first { $0.id == id }
            return ("\(id) \(worker?.profile ?? "")", worker?.state.symbol ?? "circle", worker?.state.color ?? .secondary,
                    worker?.title ?? id)
        case .shell(let id):
            let number = (snapshot?.shells?.firstIndex(of: id)).map { $0 + 1 } ?? id
            return ("Shell \(number)", "terminal", .secondary, "A shell in \(URL(fileURLWithPath: repo).lastPathComponent)")
        }
    }
}

struct TabButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let selected: Bool
    var emphasized = true
    var onClose: (() -> Void)?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .imageScale(.small)
                .foregroundStyle(tint)
            Text(title)
                .lineLimit(1)
                .foregroundStyle(selected ? .primary : .secondary)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Close tab (⌘W)")
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .glassEffect(
            selected
                ? .regular.tint(emphasized ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.08)).interactive()
                : .clear.interactive(),
            in: Capsule()
        )
        .contentShape(Capsule())
        .onTapGesture(perform: action)
    }
}
