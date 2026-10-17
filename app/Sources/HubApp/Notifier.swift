import Foundation
import HubCore
import UserNotifications

/// macOS notifications for new Needs. Only a bundled Hub.app may post them.
enum Notifier {
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestPermission() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ need: Need, repo: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(need.worker) needs you · \(URL(fileURLWithPath: repo).lastPathComponent)"
        content.subtitle = "\(need.profile): \(need.title)"
        content.body = summary(of: need)
        content.sound = .default
        content.userInfo = ["worker": need.worker, "repo": repo]
        let request = UNNotificationRequest(identifier: need.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func summary(of need: Need) -> String {
        switch need.kind {
        case .question: return need.body
        case .permissionPrompt:
            let lines = (need.prompt ?? "").split(separator: "\n").filter { !$0.hasPrefix("Do you want") }
            return "Approve? " + lines.suffix(2).joined(separator: " · ")
        case .idlePrompt: return "Idle with no Final Report."
        case .other: return need.body.split(separator: "\n").first.map(String.init) ?? ""
        }
    }
}
