import HubCore
import SwiftUI

/// ⌘K: one search over every repo, agent and Worker Echo knows, and the commands, so jumping
/// somewhere does not mean scanning tabs and the ledger.
struct QuickOpen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings
    /// Local state as an ObservableObject: the command-line tools lack the plugin `@State` needs.
    @StateObject private var search = QuickOpenSearch()
    @FocusState private var fieldFocused: Bool

    private static let shown = 12

    var body: some View {
        let results = matches
        ZStack(alignment: .top) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Ledger.ink3)
                    TextField("Go to a repo, agent, Worker or command", text: $search.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        // Search terms, not prose: no completion panel over the results.
                        .autocorrectionDisabled()
                        .textContentType(.none)
                        .focused($fieldFocused)
                        .onSubmit { run(results) }
                        .onKeyPress(.downArrow) { move(1, in: results); return .handled }
                        .onKeyPress(.upArrow) { move(-1, in: results); return .handled }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Ledger.band)

                if results.isEmpty {
                    Text("Nothing matches \u{201C}\(search.query)\u{201D}.")
                        .font(.system(size: 13))
                        .foregroundStyle(Ledger.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            QuickOpenRow(item: item, picked: index == search.picked) {
                                search.picked = index
                                run(results)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .frame(width: 600)
            .background(Ledger.paper)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 16)
            .padding(.top, 110)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
        .onChange(of: search.query) { search.picked = 0 }
        .onExitCommand(perform: close)
    }

    /// The best matches, best first; with no query, the commands and the current repo's agents.
    private var matches: [QuickOpenItem] {
        let scored = items.compactMap { item in
            quickOpenScore(search.query, item.title).map { ($0, item) }
                ?? quickOpenScore(search.query, item.detail).map { ($0 - 10, item) }
        }
        // A stable sort keeps the listing order (commands, then repos, agents, Workers) among equals.
        return scored.enumerated()
            .sorted { ($0.element.0, -$0.offset) > ($1.element.0, -$1.offset) }
            .prefix(Self.shown)
            .map(\.element.1)
    }

    private var items: [QuickOpenItem] {
        var items: [QuickOpenItem] = [
            QuickOpenItem(id: "new-orchestrator", icon: "plus", title: "New Orchestrator", detail: "Command") {
                model.showNewSession(repo: model.selectedRepo, kind: .orchestrator)
            },
            QuickOpenItem(id: "new-terminal", icon: "plus", title: "New Terminal", detail: "Command, Claude Code on its own") {
                model.showNewSession(repo: model.selectedRepo, kind: .claude)
            },
            QuickOpenItem(id: "ledger", icon: "sidebar.left", title: model.ledgerHidden ? "Show Ledger" : "Hide Ledger", detail: "Command") {
                model.ledgerHidden.toggle()
            },
            QuickOpenItem(id: "settings", icon: "gearshape", title: "Settings", detail: "Command") {
                openSettings()
            },
        ]
        for session in model.sessions {
            let repo = session.repo
            items.append(QuickOpenItem(id: "repo \(repo)", icon: "folder", title: session.name, detail: "Repo, \(session.shortPath)") {
                model.selectSession(repo)
            })
            for agent in model.agents(repo) {
                let kind = agent.isOrchestrator ? "Orchestrator" : "Claude Code"
                items.append(QuickOpenItem(id: "agent \(repo) \(agent.id)", icon: agent.isOrchestrator ? "circle.grid.cross" : "terminal",
                                           title: agent.displayName, detail: "\(kind) in \(session.name)") {
                    model.select(.agent(repo: repo, id: agent.id))
                })
            }
            for worker in model.snapshot(repo).workers {
                items.append(QuickOpenItem(id: "worker \(repo) \(worker.id)", icon: worker.isActive ? "circle.fill" : "checkmark.circle",
                                           title: "\(worker.id) \(worker.title)", detail: "\(worker.profile), \(worker.phaseLabel) in \(session.name)") {
                    model.select(.worker(repo: repo, id: worker.id))
                })
            }
        }
        return items
    }

    private func move(_ step: Int, in results: [QuickOpenItem]) {
        guard !results.isEmpty else { return }
        search.picked = (search.picked + step + results.count) % results.count
    }

    private func run(_ results: [QuickOpenItem]) {
        guard results.indices.contains(search.picked) else { return }
        let item = results[search.picked]
        close()
        item.action()
    }

    private func close() {
        model.quickOpenShown = false
    }
}

final class QuickOpenSearch: ObservableObject {
    @Published var query = ""
    /// The highlighted result; Return runs it.
    @Published var picked = 0
}

struct QuickOpenItem: Identifiable {
    let id: String
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void
}

struct QuickOpenRow: View {
    let item: QuickOpenItem
    let picked: Bool
    let run: () -> Void

    var body: some View {
        Button(action: run) {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Ledger.ink3)
                    .frame(width: 18)
                Text(item.title).lineLimit(1)
                Spacer(minLength: 12)
                Text(item.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Ledger.ink3)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(picked ? Ledger.selected : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}
