import HubCore
import SwiftUI

/// Everything waiting on the human, above the terminal, oldest first.
struct NeedsInbox: View {
    let needs: [Need]

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(needs) { need in
                    NeedCard(need: need)
                }
            }
            .padding(14)
        }
        .frame(maxHeight: 300)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct NeedCard: View {
    @EnvironmentObject private var model: AppModel
    let need: Need
    /// Local state as an ObservableObject: the command-line tools lack the plugin `@State` needs.
    @StateObject private var draft = Draft()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.yellow)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(heading).fontWeight(.semibold)
                    Text("·").foregroundStyle(.secondary)
                    Text("\(need.worker) \(need.profile): \(need.title)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Open") {
                        if let repo = model.selectedRepo { model.select(.worker(repo: repo, id: need.worker)) }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
                content
            }
        }
        .padding(14)
        .glassEffect(.regular.tint(Color.yellow.opacity(0.12)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .disabled(draft.sent)
        .opacity(draft.sent ? 0.55 : 1)
    }

    private var icon: String {
        switch need.kind {
        case .question: return "questionmark.bubble.fill"
        case .permissionPrompt: return "hand.raised.fill"
        case .idlePrompt: return "pause.circle.fill"
        case .other: return "exclamationmark.circle.fill"
        }
    }

    private var heading: String {
        switch need.kind {
        case .question: return "Question"
        case .permissionPrompt: return "Permission"
        case .idlePrompt: return "Idle"
        case .other: return "Needs you"
        }
    }

    @ViewBuilder private var content: some View {
        switch need.kind {
        case .permissionPrompt:
            Text(promptLines)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                TextField("Reason if you deny (optional)", text: $draft.text)
                    .textFieldStyle(.roundedBorder)
                Button("Deny") {
                    draft.sent = true
                    model.decide(need, approve: false, note: draft.text)
                }
                .buttonStyle(.glass)
                Button("Approve") {
                    draft.sent = true
                    model.decide(need, approve: true, note: "")
                }
                .buttonStyle(.glassProminent)
                .tint(.green)
            }
        case .question:
            Text(need.body).textSelection(.enabled)
            HStack {
                TextField("Answer", text: $draft.text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Send", action: send)
                    .buttonStyle(.glassProminent)
                    .disabled(draft.text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        case .idlePrompt:
            Text("Idle at its input with no Final Report. The Orchestrator nudges it; open the terminal to step in.")
                .foregroundStyle(.secondary)
        case .other:
            Text(need.body.split(separator: "\n").prefix(3).joined(separator: "\n"))
        }
    }

    /// The prompt without its closing question, which the buttons answer.
    private var promptLines: String {
        let lines = (need.prompt ?? need.body).split(separator: "\n", omittingEmptySubsequences: false)
        return lines.filter { !$0.hasPrefix("Do you want") }.joined(separator: "\n")
    }

    private func send() {
        let answer = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        draft.sent = true
        model.reply(need, text: answer)
    }
}

final class Draft: ObservableObject {
    @Published var text = ""
    @Published var sent = false
}
