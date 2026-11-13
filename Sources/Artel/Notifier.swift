import ArtelCore
import AppKit
import UserNotifications

/// macOS notifications for sessions that need the operator.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?
    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter crashes outside an app bundle (e.g. `swift run`).
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func setUp() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(session: SessionRecord, project: Project?, status: SessionStatus, settings: NotificationSettings) {
        guard let center else { return }
        if NSApp.isActive && !settings.whenActive { return }
        let content = UNMutableNotificationContent()
        let where_ = project.map { " · \($0.name)" } ?? ""
        content.title = "\(session.name)\(where_)"
        content.subtitle = status.activity.title.capitalizedFirst
        content.body = status.message ?? ""
        content.userInfo = ["sessionID": session.id]
        content.threadIdentifier = session.id
        if settings.sound { content.sound = .default }
        // Same id per session: a newer state replaces the older banner.
        center.add(UNNotificationRequest(identifier: "session-\(session.id)", content: content, trigger: nil))
    }

    func postLimit(agentID: String, _ w: LimitWindow) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        let agent = agentID == KimiCodeAgent.id ? "Kimi" : "Claude"
        content.title = "Лимит \(agent): \(w.label)"
        var body = "Осталось \(Int(w.remainingPercent.rounded()))%"
        if let reset = w.resetsAt { body += ", сброс через \(formatDuration(reset.timeIntervalSinceNow))" }
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "limit-\(LimitAlerts.key(w, agentID: agentID))", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["sessionID"] as? String
        Task { @MainActor in
            if let id { self.onOpen?(id) }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
