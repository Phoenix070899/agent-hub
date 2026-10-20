import AppKit
import HubCore
import SwiftUI

/// The Echo window: one tab per repo across the top, the ledger on the left (one group per
/// agent), and one terminal (or a Final Report) on the right. The ledger is how you move between
/// a repo's Orchestrators, its Claude Code sessions, and their Workers.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
            if model.daemonDown {
                DisconnectedBanner()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else if let error = model.error {
                ErrorBanner(text: error)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else if let notice = model.notice {
                NoticeBanner(text: notice)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
            HStack(alignment: .top, spacing: 0) {
                if model.ledgerCollapsed {
                    LedgerRail()
                        .frame(width: 48)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Color.clear.frame(width: 12)
                } else {
                    LedgerColumn()
                        .frame(width: model.ledgerWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    ColumnResizer(width: $model.ledgerWidth, range: 300...640, grows: .right, fallback: 392)
                }
                MainPanel()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.filesShown, let root = model.selectedCheckout {
                    ColumnResizer(width: $model.filesWidth, range: 220...600, grows: .left, fallback: 280)
                    FilesColumn(root: root)
                        .frame(width: model.filesWidth)
                        .frame(maxHeight: .infinity)
                        .ledgerSheet()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .font(.system(size: 13))
        .foregroundStyle(Ledger.ink)
        .tint(Ledger.run)
        .background(Ledger.desk)
        .ignoresSafeArea(.container, edges: .top)
        .overlay {
            if model.newSession != nil {
                NewSessionModal()
            } else if let agent = model.renaming {
                RenameModal(agent: agent)
            } else if model.quickOpenShown {
                QuickOpen()
            } else if model.fanOutShown {
                FanOutModal()
            }
        }
        .confirmationDialog(closeTitle, isPresented: closingShown, presenting: model.closing) { agent in
            Button(agent.isOrchestrator ? "Close Orchestrator" : "Close Claude Code", role: .destructive) {
                model.forgetAgent(agent.id)
            }
        } message: { agent in
            Text(agent.live
                 ? "It stops now and leaves the ledger. Echo cannot start it again."
                 : "It leaves the ledger. Echo cannot start it again.")
        }
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
        .background(TrafficLightInset(barHeight: TitleBar.height))
    }

    private var closeTitle: String {
        model.closing.map { "Close \($0.displayName)?" } ?? ""
    }

    private var closingShown: Binding<Bool> {
        Binding(get: { model.closing != nil }, set: { if !$0 { model.closing = nil } })
    }
}

// MARK: - Title bar and repo tabs

/// The top bar beside the traffic lights: Echo's mark and name, search in the middle, then how
/// many Workers are running and the plan limits.
struct TitleBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            SearchField()
            HStack(spacing: 18) {
                HStack(spacing: 8) {
                    EchoMark().frame(width: 22, height: 22)
                    Text("Echo").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ledger.ink)
                }
                Spacer(minLength: 16)
                if model.sessions.isEmpty && !model.daemonDown {
                    // Before the first session there is nothing to count: say the daemon is up.
                    HStack(spacing: 8) {
                        Circle().fill(Ledger.done).frame(width: 7, height: 7)
                        Text("Echo daemon running").foregroundStyle(Ledger.ink2)
                    }
                } else {
                    if model.runningCount > 0 {
                        Text(workers(model.runningCount, "running")).foregroundStyle(Ledger.ink2)
                    }
                    UsageInline(usage: model.usage)
                }
            }
            // Past the traffic lights, which full screen hides.
            .padding(.leading, model.fullScreen ? 16 : 86)
            .padding(.trailing, 16)
        }
        .font(.system(size: 12.5))
        .frame(height: Self.height)
    }

    static let height: CGFloat = 52
}

/// What looks like a search field at the top of the window: it opens Quick open (⌘K).
struct SearchField: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var hovering = Flag()

    var body: some View {
        Button { model.quickOpenShown = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold))
                Text("Search repos, agents, Workers and commands")
                Spacer(minLength: 8)
                Text("⌘K")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Ledger.ink2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Ledger.strip, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .font(.system(size: 13.5))
            .foregroundStyle(Ledger.ink2)
            .padding(.horizontal, 12)
            .frame(width: 520, height: 30)
            // Fill alone sets it apart, a shade darker on hover; no shadow.
            .background(hovering.on ? Ledger.band : Ledger.pill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering.on = $0 }
        .help("Go to a repo, agent, Worker or command (⌘K)")
        .accessibilityLabel("Search")
    }
}

/// Folder tabs across the top of the ledger, one per repo with a live agent or Workers at work,
/// in name order. Repos with nothing running fold into a "stopped" tab; + starts a session.
struct RepoTabs: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    let tabs = model.tabSessions
                    if tabs.isEmpty {
                        Text("No repos yet")
                            .foregroundStyle(Ledger.ink3)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                    }
                    ForEach(tabs) { session in
                        RepoTab(session: session)
                    }
                    let stopped = model.stoppedSessions
                    if !stopped.isEmpty {
                        Menu {
                            ForEach(stopped) { session in
                                Button(session.name) { model.selectSession(session.repo) }
                            }
                        } label: {
                            Text("\(stopped.count) stopped").foregroundStyle(Ledger.ink3)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                    }
                }
            }
            NewSessionMenu()
        }
        .font(.system(size: 13))
        .padding(6)
        .background(Ledger.strip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }
}

/// One repo's tab, a pill on the strip: its name and, when something waits on the human, the
/// yellow count.
struct RepoTab: View {
    @EnvironmentObject private var model: AppModel
    let session: SessionInfo
    @StateObject private var hovering = Flag()

    var body: some View {
        let selected = model.selectedRepo == session.repo
        let needs = model.snapshot(session.repo).needsYouCount
        Button { model.selectSession(session.repo) } label: {
            HStack(spacing: 6) {
                if session.isNormalOnly {
                    AgentGlyph(kind: .claude).foregroundStyle(Ledger.ink3)
                }
                Text(session.name).fontWeight(.medium)
                if needs > 0 {
                    Text("\(needs)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Ledger.markerInk)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Ledger.marker, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            .foregroundStyle(selected ? Ledger.ink : Ledger.ink2)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background {
                if selected {
                    Capsule().fill(Ledger.pill)
                } else if hovering.on {
                    Capsule().fill(Ledger.fill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering.on = $0 }
        .help("\(session.name): \(workers(model.activeCount(session.repo), "at work"))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The + at the end of the tabs: an Orchestrator, or a Terminal (Claude Code on its own).
struct NewSessionMenu: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Menu {
            Button { model.showNewSession(repo: model.selectedRepo, kind: .orchestrator) } label: {
                Text("Orchestrator")
                Text("Hands Tasks to Workers and reports back")
            }
            Button { model.showNewSession(repo: model.selectedRepo, kind: .claude) } label: {
                Text("Terminal")
                Text("Claude Code on its own, in your multiplexer")
            }
            Divider()
            Button { model.showFanOut() } label: {
                Text("Fan Out a Task")
                Text("Several Workers try it; you keep one")
            }
            .disabled(model.selectedRepo == nil)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Ledger.ink2)
        .help("New session")
        .accessibilityLabel("New session")
    }
}

/// An agent's mark: three dots for an Orchestrator, a prompt for a Claude Code session.
struct AgentGlyph: View {
    let kind: Agent.Kind

    var body: some View {
        Group {
            if kind == .orchestrator {
                Canvas { context, size in
                    let s = min(size.width, size.height) / 16
                    for (x, y, r) in [(8.0, 8.0, 2.6), (8.0, 2.4, 1.4), (12.85, 10.8, 1.4), (3.15, 10.8, 1.4)] {
                        let rect = CGRect(x: (x - r) * s, y: (y - r) * s, width: 2 * r * s, height: 2 * r * s)
                        context.fill(Path(ellipseIn: rect), with: .foreground)
                    }
                }
            } else {
                Canvas { context, size in
                    let s = min(size.width, size.height) / 16
                    var chevron = Path()
                    chevron.move(to: CGPoint(x: 2.6 * s, y: 4.2 * s))
                    chevron.addLine(to: CGPoint(x: 6.4 * s, y: 8 * s))
                    chevron.addLine(to: CGPoint(x: 2.6 * s, y: 11.8 * s))
                    context.stroke(chevron, with: .foreground,
                                   style: StrokeStyle(lineWidth: 2 * s, lineCap: .round, lineJoin: .round))
                    let bar = CGRect(x: 8.6 * s, y: 10 * s, width: 5 * s, height: 2 * s)
                    context.fill(Path(roundedRect: bar, cornerRadius: s), with: .foreground)
                }
            }
        }
        .frame(width: 13, height: 13)
        .accessibilityLabel(kind == .orchestrator ? "Orchestrator" : "Claude Code session")
    }
}

// MARK: - The ledger

struct LedgerColumn: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            RepoTabs()
            if let repo = model.selectedRepo {
                LedgerSheet(repo: repo, snapshot: model.snapshot(repo))
            } else {
                EmptyLedger()
            }
            Spacer(minLength: 0)
            Rectangle().fill(Ledger.rule).frame(height: 1)
            HStack {
                LedgerToggle()
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .ledgerSheet()
    }
}

/// Collapses or expands the ledger; it sits at the ledger's foot in both shapes.
struct LedgerToggle: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let title = model.ledgerCollapsed ? "Expand ledger" : "Collapse ledger"
        Button { model.toggleLedger() } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14))
                .foregroundStyle(Ledger.ink2)
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help("\(title) (⌘L)")
    }
}

/// The collapsed ledger: the repo's needs-you count, then each agent and a mark per Worker in its
/// state colour. Clicking one shows it, as its row in the full ledger would.
struct LedgerRail: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let repo = model.selectedRepo {
                let snapshot = model.snapshot(repo)
                ScrollView {
                    VStack(spacing: 2) {
                        if snapshot.needsYouCount > 0 {
                            Text("\(snapshot.needsYouCount)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Ledger.markerInk)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Ledger.marker, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .help("\(snapshot.needsYouCount) need you")
                                .padding(.bottom, 6)
                        }
                        ForEach(Array(snapshot.groups.enumerated()), id: \.element.id) { index, group in
                            if index > 0 {
                                Rectangle().fill(Ledger.rule).frame(width: 20, height: 1).padding(.vertical, 6)
                            }
                            RailAgent(agent: group.agent, repo: repo)
                            ForEach(workers(group, in: snapshot)) { worker in
                                RailWorker(worker: worker, repo: repo)
                            }
                        }
                    }
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                }
            }
            Spacer(minLength: 0)
            Rectangle().fill(Ledger.rule).frame(height: 1)
            LedgerToggle().padding(.vertical, 6)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .ledgerSheet()
    }

    /// In the full ledger's order: waiting on you, running, done.
    private func workers(_ group: AgentGroup, in snapshot: Snapshot) -> [WorkerRow] {
        let waiting = group.needs.compactMap(\.worker).compactMap { id in snapshot.workers.first { $0.id == id } }
        var seen = Set<String>()
        return (waiting + group.running + group.settled).filter { seen.insert($0.id).inserted }
    }
}

struct RailAgent: View {
    @EnvironmentObject private var model: AppModel
    let agent: Agent
    let repo: String

    var body: some View {
        let selected = model.selection == .agent(repo: repo, id: agent.id)
        Button { model.select(.agent(repo: repo, id: agent.id)) } label: {
            AgentGlyph(kind: agent.kind)
                .foregroundStyle(agent.live ? Ledger.ink : Ledger.ink3)
                .frame(width: 32, height: 28)
                .background(selected ? Ledger.selected : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(agent.displayName), \(agent.live ? "live" : agent.isOrchestrator ? "stopped" : "ended")")
    }
}

struct RailWorker: View {
    @EnvironmentObject private var model: AppModel
    let worker: WorkerRow
    let repo: String

    var body: some View {
        let selected = model.selection == .worker(repo: repo, id: worker.id)
        Button { model.select(.worker(repo: repo, id: worker.id)) } label: {
            StateMark(color: worker.markColor)
                .frame(width: 32, height: 22)
                .background(selected ? Ledger.selected : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if model.isUnread(worker, repo: repo) {
                        Circle().fill(Ledger.run).frame(width: 5, height: 5).padding(4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(worker.id) \(worker.profile): \(worker.title)\n\(worker.phaseLabel), quiet for \(formatAge(worker.quietSeconds))")
    }
}

/// One repo's ledger: a group per agent. New agents come from the + beside the tabs.
struct LedgerSheet: View {
    @EnvironmentObject private var model: AppModel
    let repo: String
    let snapshot: Snapshot

    var body: some View {
        let groups = snapshot.groups
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if groups.isEmpty {
                    Hint("No agents in this repo yet. Start one with + beside the tabs.")
                        .padding(.top, 14)
                }
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    // A group showing content is set apart by space; header-only ones stack tight.
                    if index > 0, model.showsContent(groups[index - 1]) || model.showsContent(group) {
                        Color.clear.frame(height: 10)
                    }
                    AgentGroupView(group: group, repo: repo)
                }
            }
            .padding(.bottom, 12)
        }
    }
}

/// One agent in the ledger: its header, then (unless folded) its Needs you, Running and Done.
struct AgentGroupView: View {
    @EnvironmentObject private var model: AppModel
    let group: AgentGroup
    let repo: String
    @StateObject private var showAllDone = Flag()
    @StateObject private var showAllRunning = Flag()

    private static let doneShown = 4
    private static let runningShown = 5

    var body: some View {
        let agent = group.agent
        let folded = model.collapsed.contains(agent.id)
        VStack(alignment: .leading, spacing: 0) {
            AgentHeader(group: group, repo: repo, folded: folded)
            if model.showsContent(group) {
                // A small inset sets the group's contents off its header band.
                VStack(alignment: .leading, spacing: 0) {
                    if let confirmation = model.confirmations[agent.id] {
                        ConfirmationLine(text: confirmation.text)
                            .padding(.leading, 18)
                            .padding(.top, 4)
                    }
                    if !group.needs.isEmpty {
                        SubHeader(title: "Needs you", count: group.needs.count)
                        ForEach(group.needs) { need in
                            NeedItem(need: need, repo: repo)
                                .padding(.leading, 26)
                                .padding(.trailing, 12)
                                .padding(.vertical, 3)
                        }
                    }
                    if agent.isOrchestrator {
                        // A Worker waiting on the human sits under Needs you, so it counts too.
                        if group.running.isEmpty && group.settled.isEmpty && !group.needs.contains(where: { $0.worker != nil }) {
                            Hint(agent.live
                                 ? "No Workers yet. Ask it for something and it hands out Tasks."
                                 : "No Workers. Start it to pick up where it left off.")
                                .padding(.leading, 18)
                                .padding(.top, group.needs.isEmpty ? 2 : 8)
                        }
                        if !group.running.isEmpty {
                            SubHeader(title: "Running", count: group.running.count)
                            ForEach(showAllRunning.on ? group.running : Array(group.running.prefix(Self.runningShown))) { worker in
                                LedgerRow(worker: worker, repo: repo)
                                    .transition(.opacity)
                            }
                            if group.running.count > Self.runningShown {
                                Button(showAllRunning.on ? "Show fewer" : "Show \(group.running.count - Self.runningShown) more") {
                                    showAllRunning.on.toggle()
                                }
                                .buttonStyle(.ledgerLink)
                                .padding(.leading, 34)
                                .padding(.vertical, 4)
                            }
                        }
                        if !group.settled.isEmpty {
                            let read = group.settled.filter { !model.isUnread($0, repo: repo) }
                            let unread = group.settled.count - read.count
                            SubHeader(title: "Done", count: group.settled.count) {
                                HStack(spacing: 12) {
                                    if unread > 0 {
                                        Text("\(unread) unread").font(.system(size: 12)).foregroundStyle(Ledger.ink3)
                                    }
                                    if group.settled.count > Self.doneShown {
                                        Button(showAllDone.on ? "Show fewer" : "Show all") { showAllDone.on.toggle() }
                                            .buttonStyle(.ledgerLink)
                                    }
                                    Menu {
                                        Button("Clear read") { model.dismiss(read) }
                                            .disabled(read.isEmpty)
                                            .help("Take the reports you have opened off this list")
                                        Button("Clear all") { model.dismiss(group.settled) }
                                            .help("Take every report off this list, read or not")
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .rotationEffect(.degrees(90))
                                            .font(.system(size: 12.5, weight: .medium))
                                            .foregroundStyle(Ledger.run)
                                            .frame(width: 16, height: 16)
                                            .contentShape(Rectangle())
                                    }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)
                                    .fixedSize()
                                    .help("More actions for this list")
                                }
                            }
                            ForEach(showAllDone.on ? group.settled : Array(group.settled.prefix(Self.doneShown))) { worker in
                                LedgerRow(worker: worker, repo: repo)
                                    .transition(.opacity)
                            }
                        }
                    }
    }
                .padding(.top, 6)
                .padding(.bottom, 4)
                // A Worker starting, settling, or leaving slides the rows below it instead of jumping.
                .animation(.easeInOut(duration: 0.2), value: (group.running + group.settled).map(\.id))
            }
        }
        .padding(.bottom, model.showsContent(group) ? 8 : 0)
    }
}

/// An agent's row in the ledger: click it to show its terminal; the chevron folds its group.
struct AgentHeader: View {
    @EnvironmentObject private var model: AppModel
    let group: AgentGroup
    let repo: String
    let folded: Bool

    var body: some View {
        let agent = group.agent
        let selected = model.selection == .agent(repo: repo, id: agent.id)
        HStack(spacing: 8) {
            Button { model.toggleCollapsed(agent.id) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(folded ? 0 : 90))
                    .foregroundStyle(Ledger.ink3)
                    .frame(width: 22, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(folded ? "Show \(agent.displayName)" : "Fold \(agent.displayName)")
            Button { model.select(.agent(repo: repo, id: agent.id)) } label: {
                HStack(spacing: 8) {
                    AgentGlyph(kind: agent.kind).foregroundStyle(Ledger.ink3)
                    Text(agent.displayName)
                        .fontWeight(.semibold)
                        .italic(agent.name == nil)
                        .foregroundStyle(agent.name == nil ? Ledger.ink2 : Ledger.ink)
                        .lineLimit(1)
                    Text(meta)
                        .font(.system(size: 12))
                        .foregroundStyle(Ledger.ink3)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if folded && !group.running.isEmpty {
                        Text("\(group.running.count) running").font(.system(size: 12)).foregroundStyle(Ledger.ink2)
                    }
                    if !group.needs.isEmpty {
                        Text("\(group.needs.count)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Ledger.markerInk)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Ledger.marker, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    Circle().fill(agent.live ? Ledger.done : Ledger.ink3).frame(width: 7, height: 7)
                    Text(state).font(.system(size: 12)).foregroundStyle(Ledger.ink2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 6)
        .padding(.trailing, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The whole row selects the agent, padding included; the chevron keeps its own click.
        .contentShape(Rectangle())
        .onTapGesture { model.select(.agent(repo: repo, id: agent.id)) }
        .background { Rectangle().fill(selected ? Ledger.selected : Color.clear) }
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(agent.live ? Ledger.run : Ledger.ink3).frame(width: 3) }
        }
        .contextMenu {
            Button("Rename…") { model.renaming = agent }
            if agent.live {
                Button(agent.isOrchestrator ? "Stop Orchestrator" : "End Session") { model.stopAgent(agent.id) }
            } else {
                Button(agent.isOrchestrator ? "Start Orchestrator" : "Resume Session") { model.startAgent(agent.id) }
            }
            Divider()
            Button(agent.isOrchestrator ? "Close Orchestrator…" : "Close Claude Code…") { model.closing = agent }
        }
        .help(agent.name == nil ? "Named after your first request" : agent.displayName)
    }

    /// "Orchestrator, opus"; the default model goes unsaid, so the row does not truncate it.
    private var meta: String {
        // "Orchestrator, feat/login, opus": what it is, the branch it works on, its model.
        [agent.isOrchestrator ? "Orchestrator" : nil, agent.branch, agent.model.map(Self.short)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private var agent: Agent { group.agent }

    private var state: String {
        if agent.live { return "live" }
        return agent.isOrchestrator ? "stopped" : "ended"
    }

    /// "claude-opus-5-5" reads "opus".
    static func short(_ model: String) -> String {
        let parts = model.split(separator: "-")
        return parts.count >= 2 && parts[0] == "claude" ? String(parts[1]) : model
    }
}

/// A section inside an agent's group: "Needs you 2".
struct SubHeader<Trailing: View>: View {
    let title: String
    let count: Int
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ledger.ink2)
            Text("\(count)").font(.system(size: 12)).foregroundStyle(Ledger.ink3).monospacedDigit()
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.leading, 34)
        .padding(.trailing, 16)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .accessibilityAddTraits(.isHeader)
    }
}

extension SubHeader where Trailing == EmptyView {
    init(title: String, count: Int) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

// MARK: - The terminal side

struct MainPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.selection {
            case .agent(let repo, let id)?:
                if let agent = model.agents(repo).first(where: { $0.id == id }) {
                    AgentPanel(repo: repo, agent: agent)
                } else {
                    ContentUnavailableView("That session is closed", systemImage: "questionmark.square.dashed",
                                           description: Text("Pick another agent in the ledger."))
                }
            case .worker(let repo, let id)?:
                WorkerPanel(repo: repo, id: id)
            case nil:
                FirstLaunch()
            }
        }
        // A previewed file covers the panel; the terminal stays attached underneath.
        .overlay {
            if let file = model.preview, file.root == model.selectedCheckout {
                FilePreviewPanel(file: file, files: model.checkoutFiles(file.root))
                    .background(Ledger.paper)
            }
        }
        .ledgerSheet()
    }
}

/// An Orchestrator's or a Claude Code session's terminal, or what to do while it is not running.
struct AgentPanel: View {
    @EnvironmentObject private var model: AppModel
    let repo: String
    let agent: Agent

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader {
                AgentGlyph(kind: agent.kind).foregroundStyle(Ledger.ink3)
                Text(agent.displayName).fontWeight(.semibold).lineLimit(1)
                Text(meta)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ledger.ink3)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if agent.live {
                    Button { model.stopAgent(agent.id) } label: {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(Ledger.ink2)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(agent.isOrchestrator ? "Stop Orchestrator" : "End session")
                    .help(agent.isOrchestrator ? "Stop the Orchestrator. Its Workers keep running." : "End this Claude Code session. You can resume it.")
                }
            }
            if agent.live {
                LiveTerminal(target: .agent(id: agent.id), repo: repo)
            } else if agent.isOrchestrator {
                StoppedPanel(repo: repo, agent: agent)
            } else {
                EndedPanel(repo: repo, agent: agent)
            }
        }
    }

    private var meta: String {
        let name = URL(fileURLWithPath: repo).lastPathComponent
        let model = agent.model ?? "default model"
        let place = (agent.head ?? agent.branch).map { "\(name) on \($0)" } ?? name
        return agent.isOrchestrator ? "Orchestrator in \(place), \(model)" : "Claude Code in \(place), \(model)"
    }
}

/// A live agent's or Worker's terminal: inside the human's multiplexer when that is on (its
/// first pane shows the target, and they can split beside it), else the terminal itself.
struct LiveTerminal: View {
    @EnvironmentObject private var model: AppModel
    let target: TerminalTarget
    let repo: String

    var body: some View {
        let shown = model.shownTarget(for: target)
        Group {
            if let shown {
                TerminalPane(target: shown, client: model.client, appearance: model.appearance,
                             keyboard: !model.modalShown && model.preview == nil && !model.treeFocused,
                             focusRequest: model.terminalFocusRequest)
            } else {
                Text("Starting the multiplexer…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(TerminalTheme.color(model.appearance.theme.foreground).opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.leading, 10)
        .padding(.vertical, 6)
        .background { TerminalBackdrop(appearance: model.appearance) }
        .opacity(model.daemonDown ? 0.45 : 1)
        // Runs again whenever the multiplexer shell changes, so one that exited is replaced.
        .task(id: "\(target.label) \(shown?.label ?? "-") \(model.multiplexer.enabled)") {
            model.ensureMux(target, repo: repo)
        }
    }
}

/// What sits behind a terminal: the theme background, or the chosen image, blurred and dimmed by it.
struct TerminalBackdrop: View {
    let appearance: TerminalAppearance
    private static var images: [String: NSImage] = [:]

    var body: some View {
        let background = TerminalTheme.color(appearance.theme.background)
        if let path = appearance.backgroundImage, let image = Self.image(at: path) {
            Color.clear
                .overlay {
                    Image(nsImage: image).resizable().scaledToFill()
                        .blur(radius: appearance.backgroundImageBlur, opaque: true)
                }
                .clipped()
                .overlay { background.opacity(appearance.backgroundImageDim) }
                // The filled image spills past the panel; clipping hides that but still hit-tests
                // it, which took clicks meant for the ledger and the Files column.
                .allowsHitTesting(false)
        } else {
            background
        }
    }

    /// Read once per path; a file that is gone falls back to the plain background.
    private static func image(at path: String) -> NSImage? {
        if let image = images[path] { return image }
        let image = NSImage(contentsOfFile: path)
        images[path] = image
        return image
    }
}

struct StoppedPanel: View {
    @EnvironmentObject private var model: AppModel
    let repo: String
    let agent: Agent

    var body: some View {
        let running = model.snapshot(repo).groups.first { $0.agent.id == agent.id }?.running.count ?? 0
        VStack(alignment: .leading, spacing: 12) {
            Text("The Orchestrator is stopped")
                .font(.system(size: 24, weight: .semibold))
            Text(running > 0
                 ? "Its \(running) running Workers carry on, and you can still approve and answer them from the ledger. Their reports wait for the Orchestrator."
                 : "None of its Workers are running.")
                .font(.system(size: 15))
                .foregroundStyle(Ledger.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Starting it resumes the same conversation, with every report it missed.")
                .font(.system(size: 15))
                .foregroundStyle(Ledger.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Button("Start Orchestrator") { model.startAgent(agent.id) }
                .buttonStyle(.ledgerLarge)
                .padding(.top, 8)
                .disabled(model.daemonDown)
        }
        .frame(maxWidth: 440, alignment: .leading)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A Claude Code session whose terminal ended: resume it, start fresh, or close it.
struct EndedPanel: View {
    @EnvironmentObject private var model: AppModel
    let repo: String
    let agent: Agent

    /// Closing it touches nothing else; said when the repo has Orchestrators that might seem at stake.
    private var othersNote: String? {
        let orchestrators = model.agents(repo).filter(\.isOrchestrator).count
        guard orchestrators > 0 else { return nil }
        let name = URL(fileURLWithPath: repo).lastPathComponent
        return "Closing it leaves \(name)\u{2019}s Orchestrator\(orchestrators == 1 ? "" : "s") and \(orchestrators == 1 ? "its" : "their") Workers running."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Code exited")
                .font(.system(size: 24, weight: .semibold))
            Text("The conversation is saved. Resume picks it up where it stopped; Start fresh opens a new one in the same repo.")
                .font(.system(size: 15))
                .foregroundStyle(Ledger.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if let others = othersNote {
                Text(others)
                    .font(.system(size: 13))
                    .foregroundStyle(Ledger.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Resume") { model.startAgent(agent.id) }
                    .buttonStyle(.ledgerLarge)
                Button("Start fresh") { model.startFresh(agent, repo: repo) }
                    .buttonStyle(.ledger)
                Spacer(minLength: 16)
                Button("Close Claude Code…") { model.closing = agent }
                    .buttonStyle(.plain)
                    .foregroundStyle(Ledger.ink2)
            }
            .padding(.top, 8)
            .disabled(model.daemonDown)
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Panels shared parts

/// A panel's title row: what the terminal below is showing.
struct PanelHeader<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ledger.band)
    }
}

struct FirstLaunch: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Start your first session")
                .font(.system(size: 28, weight: .semibold))
            Text("A session is an Orchestrator, or Claude Code on its own, working in one git repo. You talk to it; it hands Tasks to Workers and reports back. Workers keep running when this window is closed.")
                .font(.system(size: 15))
                .foregroundStyle(Ledger.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open a repo") { model.showNewSession() }
                .buttonStyle(.ledgerLarge)
                .padding(.top, 6)
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


// MARK: - Workers

struct WorkerPanel: View {
    @EnvironmentObject private var model: AppModel
    let repo: String
    let id: String
    @StateObject private var confirmStop = Flag()

    var body: some View {
        if let worker = model.snapshot(repo).workers.first(where: { $0.id == id }) {
            VStack(spacing: 0) {
                WorkerHeader(worker: worker, confirmStop: $confirmStop.on, view: viewBinding(worker),
                             comments: model.reviews[AppModel.workerKey(repo, worker)]?.count ?? 0)
                if model.workerView(repo, worker) == .changes {
                    ChangesView(repo: repo, worker: worker)
                } else if model.workerView(repo, worker) == .compare, let fanout = worker.fanout {
                    CompareView(repo: repo, fanout: fanout)
                } else if worker.isActive, worker.live, let number = worker.number {
                    LiveTerminal(target: .worker(id: number), repo: repo)
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle")
                        Text("Typing here is an Intervention. \(worker.id) does what you ask and tells the Orchestrator.")
                            .lineLimit(1)
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ledger.ink2)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Ledger.wash)
                } else {
                    FinalReportView(worker: worker)
                }
            }
            .confirmationDialog("Stop \(worker.id)?", isPresented: $confirmStop.on) {
                Button("Stop \(worker.id)", role: .destructive) { model.stopWorker(worker) }
            } message: {
                Text("Its terminal closes and the Orchestrator is told it ended without a Final Report.")
            }
        } else {
            ContentUnavailableView("\(id) is gone", systemImage: "questionmark.square.dashed",
                                   description: Text("Its row left the ledger. Pick another Worker or the Orchestrator."))
        }
    }

    private func viewBinding(_ worker: WorkerRow) -> Binding<WorkerView> {
        Binding {
            model.workerView(repo, worker)
        } set: { view in
            model.show(view, repo: repo, worker: worker)
        }
    }
}

struct WorkerHeader: View {
    let worker: WorkerRow
    @Binding var confirmStop: Bool
    /// Its terminal or Final Report, its Changes, or its fan-out compared.
    @Binding var view: WorkerView
    /// Review comments not sent yet.
    let comments: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("\(worker.id) \(worker.profile)").fontWeight(.semibold)
                Text(worker.title).foregroundStyle(Ledger.ink2).lineLimit(1)
                HStack(spacing: 6) {
                    StateMark(color: worker.markColor)
                    Text(worker.isActive ? "Running" : worker.phaseLabel)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(worker.markColor)
                .padding(.leading, 4)
                Spacer(minLength: 8)
                Picker("Show", selection: $view) {
                    Text(worker.isActive && worker.live ? "Terminal" : "Final Report").tag(WorkerView.main)
                    Text(comments > 0 ? "Changes (\(comments))" : "Changes").tag(WorkerView.changes)
                    if worker.fanout != nil {
                        Text("Compare").tag(WorkerView.compare)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if worker.isActive, worker.live {
                    Button("Stop Worker") { confirmStop = true }.buttonStyle(.ledger)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 2) {
                GridRow {
                    Fact.label("Model")
                    Fact.label(worker.branch == nil ? "Where" : "Worktree")
                    Fact.label("Latest status")
                    Fact.label("Quiet for")
                }
                GridRow {
                    Fact.value(worker.modelLine ?? "From its profile")
                    Fact.value(worker.branch ?? worker.place, mono: worker.branch != nil)
                    Fact.value(worker.progress ?? "None sent yet")
                    Fact.value(formatAge(worker.quietSeconds))
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ledger.band)
    }
}

enum Fact {
    static func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(Ledger.ink3)
    }

    static func value(_ text: String, mono: Bool = false) -> some View {
        Text(text)
            .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12.5))
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// A settled Worker: its Final Report, read as a document rather than a closed terminal.
/// Each section's text renders as Markdown, so lists, `code`, and emphasis read as written.
struct FinalReportView: View {
    let worker: WorkerRow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .firstTextBaseline) {
                    Text(worker.finalReport == nil ? "No Final Report" : "Final Report")
                        .font(.system(size: 30, weight: .bold))
                    Spacer(minLength: 8)
                    if let report = worker.finalReport {
                        Button("Copy report") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report, forType: .string)
                        }
                        .buttonStyle(.ledger)
                    }
                }
                if let report = worker.finalReport {
                    ForEach(Array(ReportSection.parse(report).enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 12) {
                            if let title = section.title {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(title).font(.system(size: 19, weight: .semibold))
                                    Rectangle().fill(Ledger.rule).frame(height: 1)
                                }
                            }
                            let blocks = parseMarkdown(section.body)
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                                    MarkdownBlockView(block: block, leading: 7, codeSize: 13.5)
                                        .padding(.top, index == 0 ? 0 : Self.gap(blocks[index - 1], block))
                                }
                            }
                            .foregroundStyle(section.title == "State" && worker.isTrouble ? Ledger.fail : Ledger.ink)
                        }
                    }
                } else {
                    Text("\(worker.id) \(worker.phaseLabel.lowercased()) without sending one. The Orchestrator has been told.")
                        .lineSpacing(7)
                        .foregroundStyle(Ledger.ink2)
                }
            }
            .font(.system(size: 15))
            .foregroundStyle(Ledger.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The file preview's spacing, opened up to match the report's larger text.
    private static func gap(_ previous: MarkdownBlock, _ block: MarkdownBlock) -> CGFloat {
        if case .bullet = previous, case .bullet = block { return 9 }
        return MarkdownBlockView.gap(previous, block) + 4
    }
}

/// A Final Report split on the Worker Contract's headings: `State:`, `Changed:`, `Verified:`.
struct ReportSection: Equatable {
    var title: String?
    var body: String

    static let headings = ["State", "Changed", "Verified"]

    static func parse(_ report: String) -> [ReportSection] {
        var sections: [ReportSection] = []
        for line in report.components(separatedBy: "\n") {
            let heading = headings.first { line.hasPrefix($0 + ":") }
            if let heading {
                let rest = line.dropFirst(heading.count + 1).trimmingCharacters(in: .whitespaces)
                sections.append(ReportSection(title: heading, body: rest))
            } else if sections.isEmpty {
                sections.append(ReportSection(title: nil, body: line))
            } else {
                sections[sections.count - 1].body += (sections[sections.count - 1].body.isEmpty ? "" : "\n") + line
            }
        }
        return sections
            .map { ReportSection(title: $0.title, body: $0.body.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0.title != nil || !$0.body.isEmpty }
    }
}


// MARK: - Ledger parts

/// One Worker in Running or Done: id, profile, Task, quiet time. Hovering or selecting it shows
/// its latest progress line.
struct LedgerRow: View {
    @EnvironmentObject private var model: AppModel
    let worker: WorkerRow
    let repo: String
    @StateObject private var hovering = Flag()

    var body: some View {
        let selected = model.selection == .worker(repo: repo, id: worker.id)
        let unread = model.isUnread(worker, repo: repo)
        Button { model.select(.worker(repo: repo, id: worker.id)) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    StateMark(color: worker.markColor)
                    Text(worker.id)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Ledger.ink3)
                        .frame(width: 32, alignment: .leading)
                    Text(worker.profile)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Ledger.ink2)
                        .lineLimit(1)
                        .frame(width: 56, alignment: .leading)
                    Text(worker.title)
                        .fontWeight(unread ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(worker.isTrouble ? Ledger.fail : Ledger.ink)
                    Spacer(minLength: 6)
                    if unread {
                        Circle().fill(Ledger.run).frame(width: 7, height: 7)
                            .accessibilityLabel("Unread")
                    }
                    Text(formatAge(worker.quietSeconds))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Ledger.ink3)
                }
                // Always drawn when there is something to say, never only on hover or selection,
                // so a row keeps its height and the list below it never jumps.
                if worker.branch != nil || detailLine != nil {
                    HStack(spacing: 8) {
                        if let branch = worker.branch {
                            Text(branch)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Ledger.ink3)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .layoutPriority(1)
                        }
                        if let line = detailLine {
                            Text(line)
                                .font(.system(size: 12))
                                .foregroundStyle(Ledger.ink2)
                                .lineLimit(1)
                                .contentTransition(.opacity)
                        }
                    }
                    .padding(.leading, 8 + 8)
                }
            }
            .padding(.leading, 34)
            .padding(.trailing, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Ledger.selected : hovering.on ? Ledger.wash : Color.clear)
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(Ledger.run).frame(width: 3) }
            }
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: selected)
            .animation(.easeOut(duration: 0.12), value: hovering.on)
            .animation(.easeInOut(duration: 0.2), value: detailLine)
        }
        .buttonStyle(.plain)
        .onHover { hovering.on = $0 }
        .help("\(worker.id) \(worker.profile): \(worker.title)\n\(worker.phaseLabel), quiet for \(formatAge(worker.quietSeconds))")
        .contextMenu {
            if worker.settledAt != nil {
                Button(unread ? "Mark as Read" : "Mark as Unread") { model.setRead(worker, repo: repo, unread) }
                Button("Dismiss") { model.dismiss([worker]) }
            }
        }
    }

    private var detailLine: String? {
        if let progress = worker.progress { return progress }
        // Under Done, "Done" says nothing; Failed or Blocked does.
        if !worker.isActive && worker.isTrouble { return worker.phaseLabel }
        return nil
    }
}

struct ConfirmationLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
            Text(text).lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Ledger.okInk)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Ledger.okWash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .transition(.opacity)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// A quiet sentence where a section is empty.
struct Hint: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(Ledger.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
    }
}

/// The ledger before any session exists: what each agent's group will hold.
struct EmptyLedger: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Orchestrator").fontWeight(.semibold)
                Text("not started").font(.system(size: 12.5))
            }
            .foregroundStyle(Ledger.ink3)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            SectionHeader(title: "Needs you", count: 0)
            Hint("Permission prompts and questions from Workers land here.")
            SectionHeader(title: "Running", count: 0)
            Hint("Workers appear here once the Orchestrator hands out Tasks.")
            SectionHeader(title: "Done", count: 0)
            Hint("Each finished Worker leaves its Final Report here until you dismiss it.")
        }
    }
}

// MARK: - Usage

/// The Claude account's plan limits, in the session bar. Click to re-read them.
struct UsageInline: View {
    @EnvironmentObject private var model: AppModel
    let usage: Usage?

    var body: some View {
        Button { model.refreshUsage() } label: {
            HStack(spacing: 14) {
                if let usage, !usage.limits.isEmpty {
                    ForEach(usage.limits.prefix(2)) { limit in
                        HStack(spacing: 4) {
                            Text(limit.name).foregroundStyle(Ledger.ink2)
                            Text("\(limit.percent)%")
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .foregroundStyle(limit.percent >= 90 ? Ledger.fail : Ledger.ink)
                            // Counts down between snapshots, which repeat an unchanged `resets`.
                            TimelineView(.everyMinute) { context in
                                if let left = limit.resetsIn(now: context.date) {
                                    Text(left).monospacedDigit().foregroundStyle(Ledger.ink3)
                                }
                            }
                        }
                    }
                } else if usage?.error != nil {
                    Text("Usage unavailable").foregroundStyle(Ledger.ink3)
                }
            }
            .opacity(usage?.refreshing == true ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var helpText: String {
        guard let usage else { return "Reading Claude usage" }
        if let error = usage.error, usage.limits.isEmpty { return error }
        let lines = usage.limits.map { limit in
            "\(limit.name): \(limit.percent)% used" + (limit.resets.map { ", resets \($0)" } ?? "")
        }
        return (lines + ["Click to refresh."]).joined(separator: "\n")
    }
}

// MARK: - Banners

struct DisconnectedBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
            VStack(alignment: .leading, spacing: 2) {
                Text("Can’t reach the daemon").fontWeight(.semibold)
                Text("Workers keep running inside it. The ledger shows the last update and reconnects on its own; approving and replying wait until then.")
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Start the daemon") { model.refreshSessions() }
                .buttonStyle(.ledgerPrimary)
        }
        .foregroundStyle(Ledger.failInk)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Ledger.failWash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct ErrorBanner: View {
    @EnvironmentObject private var model: AppModel
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
            Text(text).lineLimit(2).textSelection(.enabled)
            Spacer(minLength: 8)
            Button { model.error = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Ledger.failInk)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Ledger.failWash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A passing word about something the human just did, like a key that did nothing; it hides itself.
struct NoticeBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
            Text(text).lineLimit(2)
            Spacer(minLength: 8)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Ledger.ink2)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Ledger.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension TerminalTheme {
    static func color(_ hex: String) -> Color {
        guard let c = rgb(hex) else { return .clear }
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue)
    }
}

/// The column's width when a resize drag began; nil between drags.
final class DragStart: ObservableObject {
    @Published var width: CGFloat?
}

/// The 12pt gap between two columns, dragged to resize the column beside it; a double click
/// puts it back to its first width.
struct ColumnResizer: View {
    enum Side { case left, right }
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    /// Which way dragging makes the column wider: right for the ledger, left for Files.
    let grows: Side
    let fallback: CGFloat
    @StateObject private var drag = DragStart()
    @StateObject private var hover = Flag()

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 12)
            .frame(maxHeight: .infinity)
            .overlay {
                Capsule()
                    .fill(Ledger.rule)
                    .frame(width: 3, height: 36)
                    .opacity(hover.on || drag.width != nil ? 1 : 0)
            }
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .onHover { hover.on = $0 }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let from = drag.width ?? width
                        drag.width = from
                        let delta = grows == .right ? value.translation.width : -value.translation.width
                        width = min(max(from + delta, range.lowerBound), range.upperBound).rounded()
                    }
                    .onEnded { _ in drag.width = nil }
            )
            .onTapGesture(count: 2) { width = fallback }
            .accessibilityLabel("Resize column")
    }
}
