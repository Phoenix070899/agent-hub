import HubCore
import SwiftUI

/// The menu bar menu: what needs the human in every session, and a way back to the window.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let needs = model.sessions.flatMap { session in
            (model.snapshots[session.repo]?.needs ?? []).map { (session, $0) }
        }
        if needs.isEmpty {
            Text("Nothing needs you")
        } else {
            Section("Needs you") {
                ForEach(needs, id: \.1.id) { session, need in
                    Button("\(session.name) · \(need.worker) \(need.profile): \(Notifier.summary(of: need))") {
                        model.reveal(repo: session.repo, worker: need.worker)
                    }
                }
            }
        }
        Section("Sessions") {
            ForEach(model.sessions) { session in
                let workers = model.snapshots[session.repo]?.workers ?? []
                let running = workers.filter { $0.state == .running }.count
                Button("\(session.name) · \(session.live ? "live" : "stopped")\(running > 0 ? " · \(running) running" : "")") {
                    model.reveal(repo: session.repo, worker: nil)
                }
            }
        }
        Divider()
        Button("Open Hub") { model.reveal(repo: nil, worker: nil) }
            .keyboardShortcut("o")
        Button("Quit Hub") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
