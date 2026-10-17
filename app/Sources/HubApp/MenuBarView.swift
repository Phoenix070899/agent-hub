import HubCore
import SwiftUI

/// The menu bar menu: what needs the human, the Workers, and a way back to the window.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let needs = model.snapshot?.needs ?? []
        let workers = model.snapshot?.workers ?? []
        Text(model.repoName)
        if needs.isEmpty {
            Text("Nothing needs you")
        } else {
            Section("Needs you") {
                ForEach(needs) { need in
                    Button("\(need.worker) \(need.profile): \(Notifier.summary(of: need))") {
                        model.reveal(worker: need.worker)
                    }
                }
            }
        }
        if !workers.isEmpty {
            Section("Workers") {
                ForEach(workers) { worker in
                    Button("\(worker.state.label) · \(worker.profile): \(worker.title)") {
                        model.reveal(worker: worker.id)
                    }
                }
            }
        }
        Divider()
        Button("Open Hub") { model.reveal(worker: nil) }
            .keyboardShortcut("o")
        Button("Quit Hub") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
