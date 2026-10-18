import AppKit
import HubCore
import SwiftUI

/// Start a session: a modal in the middle of the window over a dimmed backdrop. Pick how to
/// work (an Orchestrator, or Claude Code on its own), an optional name, the model, and the repo.
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
                        VStack(spacing: 0) {
                            ForEach(repos, id: \.self) { repo in
                                RepoChoice(repo: repo, status: status(repo), picked: form.picked == repo) {
                                    form.picked = repo
                                }
                            }
                        }
                    }
                    .frame(height: min(CGFloat(repos.count) * 53, 212))
                }
                Button("Choose another folder…", action: choose)
                    .buttonStyle(.ledgerLink)
                    .padding(.horizontal, 24)
                    .padding(.top, 10)

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Name")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Ledger.ink2)
                        .frame(width: 44, alignment: .leading)
                    TextField("optional", text: $form.name)
                        .textFieldStyle(.plain)
                    .ledgerField()
                        .focused($nameFocused)
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)

                HStack(spacing: 10) {
                    Text("Model")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Ledger.ink2)
                        .frame(width: 44, alignment: .leading)
                    Picker("Model", selection: $form.model) {
                        ForEach(AppModel.models, id: \.self) { name in
                            Text(name.isEmpty ? "Default model" : name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)

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
                    Button(form.kind == .orchestrator ? "Start Orchestrator" : "Start Claude Code", action: start)
                        .buttonStyle(.ledgerPrimary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(form.picked == nil || model.daemonDown)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 22)
            }
            .frame(width: 560)
            .background(Ledger.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 16)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .onAppear {
            let request = model.newSession
            form.kind = request?.kind ?? .orchestrator
            if form.picked == nil { form.picked = request?.repo ?? model.selectedRepo ?? repos.first }
            // After the terminal behind has let go of the keyboard.
            DispatchQueue.main.async { nameFocused = true }
        }
        .onExitCommand(perform: close)
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

    private func start() {
        guard let picked = form.picked else { return }
        model.open(repo: picked, kind: form.kind, name: form.name, model: form.model)
        close()
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
            .padding(.horizontal, 24)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(picked ? Ledger.selected : Color.clear)
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
            .shadow(color: .black.opacity(0.25), radius: 30, y: 16)
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
