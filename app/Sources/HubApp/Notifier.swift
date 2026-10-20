import Foundation
import HubCore
import UserNotifications

/// macOS notifications for new Needs. Only a bundled Echo.app may post them. A permission prompt's
/// notification carries Approve and Deny, so it can be settled without opening the window.
enum Notifier {
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static let approve = "approve"
    static let deny = "deny"
    private static let permissionCategory = "permission"

    static func requestPermission() {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: permissionCategory,
                actions: [
                    UNNotificationAction(identifier: approve, title: "Approve", options: []),
                    UNNotificationAction(identifier: deny, title: "Deny", options: [.destructive]),
                ],
                intentIdentifiers: [],
                options: []
            ),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `agent` is the Need's Orchestrator or Normal session, for the subtitle.
    static func post(_ need: Need, repo: String, agent: Agent?) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = need.headline
        let repoName = URL(fileURLWithPath: repo).lastPathComponent
        content.subtitle = agent.map { "\(repoName), \($0.displayName)" } ?? repoName
        content.body = summary(of: need)
        content.sound = .default
        var info: [String: Any] = ["repo": repo]
        if let worker = need.worker { info["worker"] = worker }
        if let agent = need.agent { info["agent"] = agent }
        if need.kind == .permissionPrompt {
            content.categoryIdentifier = permissionCategory
            if let command = need.command { info["command"] = command }
        }
        content.userInfo = info
        let request = UNNotificationRequest(identifier: need.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func summary(of need: Need) -> String {
        switch need.kind {
        case .question: return need.body
        case .permissionPrompt: return need.command ?? need.body
        case .idlePrompt: return "Idle at its prompt with no Final Report."
        case .other: return need.body.split(separator: "\n").first.map(String.init) ?? ""
        }
    }
}
