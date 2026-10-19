import AppKit
import HubCore
import SwiftUI
import UserNotifications

@main
struct HubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Echo", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        // Echo draws its own top bar (logo, search, usage) beside the traffic lights.
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1280, height: 820)
        .commands {
            // ⌘W closes the tmux pane in focus, or the window when no tmux view is showing.
            CommandGroup(replacing: .saveItem) {
                Button(model.canSplit ? "Close Pane" : "Close") { model.closePane() }
                    .keyboardShortcut("w")
            }
            CommandGroup(replacing: .newItem) {
                Button("New Orchestrator…") { model.showNewSession(repo: model.selectedRepo, kind: .orchestrator) }
                    .keyboardShortcut("n")
                Button("New Terminal…") { model.showNewSession(repo: model.selectedRepo, kind: .claude) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Session") {
                Button("Quick Open…") { model.quickOpenShown = true }
                    .keyboardShortcut("k")
                Divider()
                Button("Show First Agent") { model.showFirstAgent() }
                    .keyboardShortcut("0")
                    .disabled(model.selectedRepo == nil)
                Button(model.ledgerHidden ? "Show Ledger" : "Hide Ledger") { model.ledgerHidden.toggle() }
                    .keyboardShortcut("l")
                Button(model.changesSelected ? "Hide Changes" : "Show Changes") { model.toggleChanges() }
                    .keyboardShortcut("d", modifiers: [.command, .option])
                    .disabled(model.selectedWorker == nil)
                Button("Next Repo") { model.cycleSession(forward: true) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Repo") { model.cycleSession(forward: false) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Divider()
                Button("Split Pane Right") { model.splitPane(down: false) }
                    .keyboardShortcut("d")
                    .disabled(!model.canSplit)
                Button("Split Pane Down") { model.splitPane(down: true) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(!model.canSplit)

                Divider()
                ForEach(Array(model.tabSessions.prefix(9).enumerated()), id: \.element.repo) { index, session in
                    Button(session.name) { model.selectSession(session.repo) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
            }
        }

        Settings {
            SettingsView().environmentObject(model)
        }

        MenuBarExtra {
            MenuBarView().environmentObject(model)
        } label: {
            MenuBarLabel(count: model.needsYouCount)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Closing the window keeps the app in the menu bar, so notifications keep coming.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Notifier.isAvailable {
            UNUserNotificationCenter.current().delegate = self
        }
        AppModel.shared.start()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Approve and Deny act on the Worker's prompt from the notification itself; anything else
    /// opens the window on that Worker.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let worker = info["worker"] as? String
        let repo = info["repo"] as? String
        let agent = info["agent"] as? Int
        let command = info["command"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            let approve = action == Notifier.approve
            if action == Notifier.approve || action == Notifier.deny {
                if let worker, let repo {
                    AppModel.shared.decide(worker: worker, repo: repo, agent: agent, approve: approve, note: "",
                                           what: command)
                } else if let agent {
                    AppModel.shared.decide(agent: agent, approve: approve, note: "", what: command)
                }
            } else {
                AppModel.shared.reveal(repo: repo, worker: worker, agent: agent)
            }
        }
    }
}
