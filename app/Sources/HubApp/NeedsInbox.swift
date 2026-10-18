import HubCore
import SwiftUI

/// One thing waiting on the human, in the ledger's Needs you section: who and what on one line,
/// then the command and its buttons, or the question and a reply field.
struct NeedItem: View {
    @EnvironmentObject private var model: AppModel
    let need: Need
    let repo: String
    /// Local state as an ObservableObject: the command-line tools lack the plugin `@State` needs.
    @StateObject private var draft = Draft()
    @FocusState private var replyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The whole line opens what asked, not just the highlighted words.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Marked(need.headline)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(age).font(.system(size: 12)).foregroundStyle(Ledger.ink3).monospacedDigit()
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .help("Open \(need.worker ?? need.title)")
            content
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Ledger.needCard, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .disabled(draft.sent || !model.connected)
        .opacity(draft.sent ? 0.55 : 1)
        .contextMenu {
            Button("Open \(need.worker ?? need.title)", action: open)
        }
        .onAppear(perform: takeReplyFocus)
        .onChange(of: model.replyFocus) { takeReplyFocus() }
    }

    /// Answer in the menu bar asked for this question's reply field. It waits a beat so the
    /// terminal that Answer just showed has taken the keyboard first.
    private func takeReplyFocus() {
        guard model.replyFocus == need.id else { return }
        model.replyFocus = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { replyFocused = true }
    }

    /// Shows the terminal the Need is about: the Worker's, or the Normal session's own.
    private func open() {
        if let worker = need.worker {
            model.select(.worker(repo: repo, id: worker))
        } else if let agent = need.agent {
            model.select(.agent(repo: repo, id: agent))
        }
    }

    private var age: String {
        formatAge(max(Int(Date().timeIntervalSince1970) - need.at, 0))
    }

    @ViewBuilder private var content: some View {
        switch need.kind {
        case .permissionPrompt:
            HStack(spacing: 8) {
                Text(need.command ?? need.body)
                    .font(Ledger.mono)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Ledger.wash, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .help(need.promptLines.joined(separator: "\n"))
                Button("Approve") {
                    draft.sent = true
                    model.decide(need, repo: repo, approve: true, note: "")
                }
                .buttonStyle(.ledgerPrimary)
                Button("Deny") {
                    // A Normal session's prompt has only the human to tell: deny it outright.
                    if need.worker == nil {
                        draft.sent = true
                        model.decide(need, repo: repo, approve: false, note: "")
                    } else {
                        draft.denying.toggle()
                    }
                }
                .buttonStyle(.ledger)
            }
            if draft.denying {
                HStack(spacing: 8) {
                    TextField("Why, for \(need.worker ?? "it") (optional)", text: $draft.text)
                        .textFieldStyle(.plain)
                    .ledgerField()
                        .onSubmit(deny)
                    Button("Deny", action: deny).buttonStyle(.ledgerPrimary)
                }
            }
        case .question:
            Text(need.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Reply to \(need.worker ?? "it")", text: $draft.text, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .ledgerField()
                    .focused($replyFocused)
                    .onSubmit(send)
                Button("Send", action: send)
                    .buttonStyle(.ledger)
                    .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        case .idlePrompt:
            HStack(spacing: 8) {
                Text("Idle at its prompt with no Final Report. The Orchestrator nudges it.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ledger.ink2)
                Spacer(minLength: 4)
                Button("Open", action: open).buttonStyle(.ledger)
            }
        case .other:
            HStack(alignment: .top, spacing: 8) {
                Text(need.body.split(separator: "\n").prefix(3).joined(separator: "\n"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ledger.ink2)
                Spacer(minLength: 4)
                Button("Open", action: open).buttonStyle(.ledger)
            }
        }
    }

    private func deny() {
        draft.sent = true
        model.decide(need, repo: repo, approve: false, note: draft.text)
    }

    private func send() {
        let answer = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        draft.sent = true
        model.reply(need, repo: repo, text: answer)
    }
}

/// One on/off bit of view state, for views that would otherwise need `@State`.
final class Flag: ObservableObject {
    @Published var on = false
}

final class Draft: ObservableObject {
    @Published var text = ""
    @Published var sent = false
    @Published var denying = false
}

extension Need {
    /// Who wants what, for the highlighter: "w21 sasuke wants to run".
    var headline: String {
        let who = worker.map { "\($0) \(profile)" } ?? "Claude Code"
        switch kind {
        case .question: return "\(who) asks"
        case .permissionPrompt: return "\(who) wants to run"
        case .idlePrompt: return "\(who) is idle"
        case .other: return "\(who) needs you"
        }
    }
}
