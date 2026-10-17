import HubCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            Detail()
        }
        .toolbar { SessionToolbar() }
        .navigationTitle(model.repoName)
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

struct Sidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            Section("Orchestrator") {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.repoName).fontWeight(.semibold)
                        Text(model.snapshot?.orchestrator.live == true ? "Live" : "Stopped")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle()
                        .fill(model.snapshot?.orchestrator.live == true ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                }
                .padding(.vertical, 3)
                .tag(Selection.orchestrator)
            }
            Section("Workers") {
                let workers = model.snapshot?.workers ?? []
                if workers.isEmpty {
                    Text("No Workers yet")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(workers) { worker in
                    WorkerRowView(worker: worker)
                        .tag(Selection.worker(worker.id))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { CountsBar() }
    }
}

struct WorkerRowView: View {
    let worker: WorkerRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: worker.state.symbol)
                .foregroundStyle(worker.state.color)
                .symbolEffect(.pulse, isActive: worker.state == .running)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(worker.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
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
        .padding(.vertical, 3)
        .help("\(worker.id) · \(worker.state.label)")
    }
}

/// The counts the terminal band shows, at the foot of the sidebar.
struct CountsBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let workers = model.snapshot?.workers ?? []
        HStack(spacing: 12) {
            ForEach([WorkerState.needsYou, .running, .done, .failed], id: \.self) { state in
                let count = workers.filter { $0.state == state }.count
                if state != .failed || count > 0 {
                    Label("\(count)", systemImage: state.symbol)
                        .foregroundStyle(count > 0 ? state.color : Color.secondary)
                        .help(state.label)
                }
            }
            Spacer()
            if !model.connected {
                Label("Reconnecting", systemImage: "bolt.horizontal.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }
}

struct Detail: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                ErrorBanner(text: error)
            }
            let needs = model.snapshot?.needs ?? []
            if !needs.isEmpty {
                NeedsInbox(needs: needs)
                Divider()
            }
            terminal
        }
    }

    @ViewBuilder private var terminal: some View {
        switch model.selection {
        case .worker(let id)?:
            if let worker = model.snapshot?.workers.first(where: { $0.id == id }) {
                if worker.live, let number = worker.number {
                    TerminalPane(target: .worker(id: number), client: model.client)
                } else {
                    FinishedWorker(worker: worker)
                }
            }
        default:
            if let repo = model.repo, model.snapshot?.orchestrator.live == true {
                TerminalPane(target: .orchestrator(repo: repo), client: model.client)
            } else if model.repo != nil {
                ContentUnavailableView {
                    Label("Orchestrator stopped", systemImage: "sparkles")
                } actions: {
                    Button("Start Orchestrator") { model.restartOrchestrator() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
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
        ToolbarItem(placement: .navigation) {
            Menu {
                ForEach(model.sessions) { session in
                    Button {
                        model.open(repo: session.repo)
                    } label: {
                        Label(session.name, systemImage: session.live ? "circle.fill" : "circle")
                    }
                }
                Divider()
                Button("New Session…") { model.chooseSession() }
            } label: {
                Label("Sessions", systemImage: "rectangle.stack")
            }
            .help("Switch Hub Session")
        }
        ToolbarItem(placement: .primaryAction) {
            if model.snapshot?.orchestrator.live == true {
                Button { model.stopOrchestrator() } label: { Label("Stop Orchestrator", systemImage: "stop.circle") }
                    .help("Stop the Orchestrator; its Workers keep running")
            }
        }
    }
}
