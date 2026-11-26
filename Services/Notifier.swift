import AppKit
import UserNotifications

/// Posts alerts. The app uses macOS notifications; tests record what would have been posted.
@MainActor
protocol Notifier: AnyObject {
    /// Asks macOS to allow notifications, once; later calls return the answer given.
    func requestPermission() async -> Bool
    func post(id: String, title: String, body: String, site: SiteKey)
}

@MainActor
final class SystemNotifier: Notifier {
    nonisolated static let siteKey = "site"

    func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(id: String, title: String, body: String, site: SiteKey) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = site.storageKey
        content.userInfo = [Self.siteKey: site.storageKey]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Notifications for this app in System Settings, for when permission was refused.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=sh.runlight.mac")!
}
