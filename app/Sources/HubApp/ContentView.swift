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
                    .buttonStyle(.borderless)
                Spacer()
                if !model.connected {
                    Label("Reconnecting", systemImage: "bolt.horizontal.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.bar)
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
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(cardSelected ? 0.08 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(cardSelected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: 1)
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
            terminal
            UsageFooter(usage: model.usage)
        }
    }

    @ViewBuilder private var terminal: some View {
        switch model.selection {
        case .worker(let repo, let id)?:
            if let worker = model.snapshots[repo]?.workers.first(where: { $0.id == id }) {
                if worker.live, let number = worker.number {
                    TerminalPane(target: .worker(id: number), client: model.client)
                } else {
                    FinishedWorker(worker: worker)
                }
            }
        case .orchestrator(let repo)?:
            if model.snapshots[repo]?.orchestrator.live == true {
                TerminalPane(target: .orchestrator(repo: repo), client: model.client)
            } else {
                ContentUnavailableView {
                    Label("Orchestrator stopped", systemImage: "sparkles")
                } description: {
                    Text("Its Workers keep running. Starting it resumes its conversation.")
                } actions: {
                    Button("Start Orchestrator") { model.open(repo: repo) }
                        .buttonStyle(.borderedProminent)
                }
            }
        case nil:
            ContentUnavailableView {
                Label("No Hub Session", systemImage: "folder.badge.plus")
            } description: {
                Text("Open a git repo to start its Orchestrator.")
            } actions: {
                Button("New Session…") { model.chooseSession() }
                    .buttonStyle(.borderedProminent)
            }
        }
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
        .padding(.horizontal, 14)
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
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
