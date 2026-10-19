import AppKit
import HubCore
import SwiftUI

/// Start a session: a modal in the middle of the window over a dimmed backdrop. Pick how to
/// work (an Orchestrator, or Claude Code on its own), the repo, an optional name, an optional
/// GitHub issue to start on, and the model.
struct NewSessionModal: View {
    @EnvironmentObject private var model: AppModel
    /// Local state as an ObservableObject: the command-line tools lack the plugin `@State` needs.
    @StateObject private var form = NewSessionForm()
    @FocusState private var nameFocused: Bool

    private var repos: [String] {
        var seen = Set<String>()
        return (form.chosen + model.sessions.map(\.repo)).filter { seen.insert($0).inserted }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Start a session")
                        .font(.system(size: 20, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Pick how you want to work, then a git repo.")
                        .foregroundStyle(Ledger.ink2)
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 14)

                FieldLabel("Mode")
                HStack(spacing: 10) {
                    ModeCard(kind: .orchestrator, picked: form.kind == .orchestrator,
                             title: "Orchestrator",
                             detail: "You talk to an Orchestrator. It hands Tasks to Workers and reports back.") {
                        form.kind = .orchestrator
                    }
                    ModeCard(kind: .claude, picked: form.kind == .claude,
                             title: "Normal",
                             detail: "One Claude Code terminal in the repo. Just you and the agent.") {
                        form.kind = .claude
                    }
                }
                .padding(.horizontal, 24)

                FieldLabel("Repos Echo knows")
                    .padding(.top, 18)
                if repos.isEmpty {
                    Text("No repos yet. Choose the folder of a git repo to start.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Ledger.ink2)
                        .padding(.horizontal, 24)
                } else {
                    ScrollView {
                        // Inset like every other field, so a picked row's fill stops short of the edges.
                        VStack(spacing: 2) {
                            ForEach(repos, id: \.self) { repo in
                                RepoChoice(repo: repo, status: status(repo), picked: form.picked == repo) {
                                    form.picked = repo
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    .frame(height: min(CGFloat(repos.count) * 55, 220))
                }
                Button("Choose another folder…", action: choose)
                    .buttonStyle(.ledgerLink)
                    .padding(.horizontal, 24)
                    .padding(.top, 10)

                if form.picked != nil {
                    CreateFromSection(form: form, submit: start)
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                }

                // Name and model share a row, keeping the dialog short enough for small windows.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Name")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Ledger.ink2)
                        .frame(width: 44, alignment: .leading)
                    TextField(namePlaceholder, text: $form.name)
                        .textFieldStyle(.plain)
                        .ledgerField()
                        .focused($nameFocused)
                    Picker("Model", selection: $form.model) {
                        ForEach(AppModel.models, id: \.self) { name in
                            Text(name.isEmpty ? "Default model" : name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                if let note = joinNote {
                    Text(note)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Ledger.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                        .padding(.top, 14)
                }

                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel", action: close)
                        .buttonStyle(.ledger)
                        .keyboardShortcut(.cancelAction)
                    Button(startTitle, action: start)
                        .buttonStyle(.ledgerPrimary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(form.picked == nil || model.daemonDown || form.starting)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 22)
            }
            .frame(width: 560)
            .background(Ledger.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            // A hairline, not a shadow, sets it apart from the dimmed window.
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ledger.rule))
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .onAppear {
            let request = model.newSession
            form.kind = request?.kind ?? .orchestrator
            if form.picked == nil { form.picked = request?.repo ?? model.selectedRepo ?? repos.first }
            loadBranches()
            // Without a repo there is no Create from; start at the name.
            if form.picked == nil { DispatchQueue.main.async { nameFocused = true } }
        }
        .onChange(of: form.picked) { loadBranches() }
        .onExitCommand(perform: close)
    }

    private var namePlaceholder: String {
        switch form.choice {
        case .name(let text)?: text
        case .issue?: "optional; the issue names it"
        default: "optional"
        }
    }

    private func loadBranches() {
        guard let repo = form.picked else { return }
        form.branches = []
        model.loadBranches(repo) { listed in
            guard form.picked == repo else { return }
            form.branches = listed.branches
            form.current = listed.current
            if !listed.branches.contains(where: { $0.name == form.base }) {
                form.base = listed.current.isEmpty ? listed.branches.first?.name ?? "" : listed.current
            }
        }
    }

    /// What a repo has running, for its row: "Orchestrator live", "Claude Code live", "stopped".
    private func status(_ repo: String) -> String? {
        let agents = model.agents(repo)
        if agents.contains(where: { $0.live && $0.isOrchestrator }) { return "Orchestrator live" }
        if agents.contains(where: \.live) { return "Claude Code live" }
        return agents.isEmpty ? nil : "stopped"
    }

    /// When the picked repo already has Orchestrators, where the new agent goes.
    private var joinNote: String? {
        guard let repo = form.picked else { return nil }
        let count = model.agents(repo).filter { $0.isOrchestrator && $0.live }.count
        guard count > 0 else { return nil }
        let name = URL(fileURLWithPath: repo).lastPathComponent
        let newcomer = form.kind == .orchestrator ? "The new Orchestrator" : "Claude Code"
        return "\(name) already has \(count) Orchestrator\(count == 1 ? "" : "s"). \(newcomer) joins in the \(name) tab as its own group, and they all keep running."
    }

    private func choose() {
        guard let folder = model.chooseFolder() else { return }
        form.chosen.insert(folder, at: 0)
        form.picked = folder
    }

    private var startTitle: String {
        if form.starting { return form.choice.map { if case .issue = $0 { "Reading the issue…" } else { "Starting…" } } ?? "Starting…" }
        return form.kind == .orchestrator ? "Start Orchestrator" : "Start Claude Code"
    }

    /// Starts the agent where Create from says: the repo's checkout, a branch, or a new branch in
    /// its own worktree; from an issue, it reads the issue first and starts on it. A failure keeps
    /// the dialog open and says why.
    private func start() {
        guard let picked = form.picked, !form.starting else { return }
        let name = form.name.trimmingCharacters(in: .whitespaces)
        switch form.choice {
        case nil:
            model.open(repo: picked, kind: form.kind, name: name, model: form.model)
            close()
        case .branch(let branch)?:
            launch(picked, name: name, branch: branch)
        case .name(let text)?:
            launch(picked, name: name.isEmpty ? text : name, newBranch: fanoutBranch(text))
        case .issue(let typed)?:
            guard let reference = issueReference(typed) else {
                form.problem = "Type an issue number, like 12, or its link, like https://github.com/owner/repo/issues/12."
                return
            }
            form.starting = true
            Task {
                do {
                    let issue = try await AppModel.fetchIssue(reference, in: picked)
                    launch(picked, name: name.isEmpty ? issue.name : name,
                           newBranch: fanoutBranch("\(issue.number) \(issue.title)"), request: issue.request)
                } catch {
                    form.starting = false
                    form.problem = "\(error)"
                }
            }
        }
    }

    private func launch(_ repo: String, name: String, branch: String? = nil, newBranch: String? = nil, request: String? = nil) {
        form.starting = true
        form.problem = nil
        model.open(repo: repo, kind: form.kind, name: name, model: form.model, request: request,
                   branch: branch, newBranch: newBranch, base: newBranch == nil ? nil : form.base) { problem in
            form.starting = false
            if let problem { form.problem = problem } else { close() }
        }
    }

    private func close() {
        model.newSession = nil
    }
}

final class NewSessionForm: ObservableObject {
    @Published var kind: Agent.Kind = .orchestrator
    @Published var name = ""
    @Published var model = ""
    @Published var picked: String?
    /// Create from: which tab, and what is typed or picked there.
    @Published var tab: CreateFromTab = .smart
    @Published var from = ""
    @Published var pickedBranch: String?
    /// The picked repo's branches and its checked-out one; new branches start from `base`.
    @Published var branches: [RepoBranch] = []
    @Published var current = ""
    @Published var base = ""
    /// Why the agent could not start: an unreadable issue, a branch git refused.
    @Published var problem: String?
    /// True while the issue is read or the agent starts.
    @Published var starting = false

    /// Where the new agent works; nil means the repo's own checkout.
    var choice: CreateFrom? {
        let text = from.trimmingCharacters(in: .whitespaces)
        switch tab {
        case .smart: return smartCreateFrom(text, branches: branches.map(\.name))
        case .github: return text.isEmpty ? nil : .issue(text)
        case .branch: return pickedBranch.map(CreateFrom.branch)
        case .name: return text.isEmpty ? nil : .name(text)
        }
    }
    /// Folders chosen with the open panel this time, listed first.
    @Published var chosen: [String] = []
}

/// A small caption above a field in a modal.
struct FieldLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Ledger.ink2)
            .padding(.horizontal, 24)
            .padding(.bottom, 6)
    }
}

/// One of the two ways to work, as a card you pick.
struct ModeCard: View {
    let kind: Agent.Kind
    let picked: Bool
    let title: String
    let detail: String
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    AgentGlyph(kind: kind)
                    Text(title).fontWeight(.semibold)
                    Spacer(minLength: 0)
                    Image(systemName: picked ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(picked ? Ledger.ink : Ledger.ink3)
                }
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ledger.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(picked ? Ledger.chosen : Ledger.wash,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

struct RepoChoice: View {
    let repo: String
    let status: String?
    let picked: Bool
    let pick: () -> Void

    var body: some View {
        let info = SessionInfo(repo: repo, live: false)
        Button(action: pick) {
            HStack(spacing: 10) {
                Image(systemName: picked ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(picked ? Ledger.ink : Ledger.ink3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.name).fontWeight(.semibold)
                    Text(info.shortPath)
                        .font(Ledger.mono)
                        .foregroundStyle(Ledger.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let status {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(Ledger.ink2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(picked ? Ledger.chosen : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// Rename an Orchestrator or a Claude Code session.
struct RenameModal: View {
    @EnvironmentObject private var model: AppModel
    let agent: Agent
    @StateObject private var draft = Draft()
    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("Rename \(agent.isOrchestrator ? "Orchestrator" : "session")")
                    .font(.system(size: 18, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 12)
                TextField(agent.displayName, text: $draft.text)
                    .textFieldStyle(.plain)
                    .ledgerField()
                    .focused($nameFocused)
                    .padding(.horizontal, 24)
                    .onSubmit(save)
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel", action: close)
                        .buttonStyle(.ledger)
                        .keyboardShortcut(.cancelAction)
                    Button("Rename", action: save)
                        .buttonStyle(.ledgerPrimary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 20)
            }
            .frame(width: 420)
            .background(Ledger.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            // A hairline, not a shadow, sets it apart from the dimmed window.
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ledger.rule))
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .onAppear {
            if draft.text.isEmpty { draft.text = agent.name ?? "" }
            DispatchQueue.main.async { nameFocused = true }
        }
        .onExitCommand(perform: close)
    }

    private func save() {
        model.rename(agent.id, to: draft.text)
        close()
    }

    private func close() {
        model.renaming = nil
    }
}
