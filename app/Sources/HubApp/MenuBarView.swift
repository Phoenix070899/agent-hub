import AppKit
import HubCore
import SwiftUI

/// The menu bar panel: everything waiting on the human across sessions, answerable in place,
/// and a way back to the window.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let waiting = model.sessions.filter { model.snapshot($0.repo).needsYouCount > 0 }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Needs you").font(.system(size: 15, weight: .semibold))
                if !waiting.isEmpty {
                    Text("\(model.needsYouCount) across \(waiting.count) session\(waiting.count == 1 ? "" : "s")")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Ledger.ink3)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)

            if waiting.isEmpty {
                Text("Nothing is waiting on you.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Ledger.ink2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            ForEach(waiting) { session in
                Text(session.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Ledger.ink2)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
                ForEach(model.snapshot(session.repo).needs) { need in
                    MenuNeedRow(need: need, repo: session.repo, agent: agentName(need, repo: session.repo))
                }
            }

            Color.clear.frame(height: 10)
            Text(summary)
                .font(.system(size: 12.5))
                .foregroundStyle(Ledger.ink2)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            MenuRow(title: "Open Echo", shortcut: "⌘O") { model.reveal(repo: nil, worker: nil) }
                .keyboardShortcut("o")
            MenuRow(title: "New session") { model.showNewSession() }
            MenuRow(title: "Quit Echo", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
            Text("Quitting the app leaves every Worker running.")
                .font(.system(size: 11.5))
                .foregroundStyle(Ledger.ink3)
                .padding(.horizontal, 14)
                .padding(.top, 2)
                .padding(.bottom, 10)
        }
        .font(.system(size: 13))
        .foregroundStyle(Ledger.ink)
        .frame(width: 380)
        .background(Ledger.paper)
    }

    private var summary: String {
        let live = model.sessions.filter(\.live).count
        return "\(workers(model.runningCount, "running")) in \(live) session\(live == 1 ? "" : "s")"
    }

    /// Which agent asked, when the repo runs more than one.
    private func agentName(_ need: Need, repo: String) -> String? {
        let agents = model.agents(repo)
        guard agents.count > 1, let id = need.agent else { return nil }
        return agents.first { $0.id == id }?.displayName
    }
}

/// One waiting item: approve or deny a command in place, or jump to a question.
struct MenuNeedRow: View {
    @EnvironmentObject private var model: AppModel
    let need: Need
    let repo: String
    var agent: String?

    var body: some View {
        HStack(spacing: 8) {
            Marked(need.headline)
                .lineLimit(1)
                .help((agent.map { "\($0)\n" } ?? "") + (need.command ?? need.body))
            Spacer(minLength: 6)
            if need.kind == .permissionPrompt {
                Button("Approve") { model.decide(need, repo: repo, approve: true, note: "") }
                    .buttonStyle(.ledgerPrimary)
                Button("Deny") { model.decide(need, repo: repo, approve: false, note: "") }
                    .buttonStyle(.ledger)
            } else {
                Button(need.kind == .question ? "Answer" : "Open") {
                    if need.kind == .question { model.replyFocus = need.id }
                    model.reveal(repo: repo, worker: need.worker, agent: need.agent)
                }
                    .buttonStyle(.ledger)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .disabled(!model.connected)
    }
}

struct MenuRow: View {
    let title: String
    var shortcut: String?
    let action: () -> Void
    @StateObject private var hovering = Flag()

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(Ledger.ink3) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(hovering.on ? Ledger.selected : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering.on = $0 }
    }
}

/// The menu bar shows Echo's mark and how many things need the human, and nothing else.
struct MenuBarLabel: View {
    let count: Int

    var body: some View {
        if count > 0 {
            HStack(spacing: 3) {
                Image(nsImage: EchoGlyph.image)
                Text("\(count)")
            }
        } else {
            Image(nsImage: EchoGlyph.image)
        }
    }
}

/// The app's mark at menu bar size: one solid square and two fading echoes behind it, drawn as a
/// template image so macOS tints it for light and dark menu bars.
enum EchoGlyph {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            func square(_ x: CGFloat, _ y: CGFloat) -> NSBezierPath {
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 7.5, height: 7.5), xRadius: 1.8, yRadius: 1.8)
            }
            for (x, y, alpha) in [(7.0, 1.5, 0.45), (4.5, 4.0, 0.7)] {
                NSColor.black.withAlphaComponent(alpha).setStroke()
                let path = square(x, y)
                path.lineWidth = 1.1
                path.stroke()
            }
            NSColor.black.setFill()
            square(1.5, 7).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Echo"
        return image
    }()
}
