import AppKit
import HubCore
import SwiftUI
import UserNotifications

@main
struct HubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Hub", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session…") { model.chooseSession() }
                    .keyboardShortcut("n")
            }
        }

        MenuBarExtra {
            MenuBarView().environmentObject(model)
        } label: {
            MenuBarLabel(count: model.needsYouCount)
        }
    }
}

/// The menu bar shows how many things need the human, and nothing else.
struct MenuBarLabel: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Label("\(count)", systemImage: "exclamationmark.bubble.fill")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "square.grid.2x2")
        }
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

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let worker = info["worker"] as? String
        let repo = info["repo"] as? String
        await MainActor.run { AppModel.shared.reveal(repo: repo, worker: worker) }
    }
}
