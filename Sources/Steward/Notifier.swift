import Foundation
import UserNotifications

/// Local notifications (the low disk space alert). Asks permission the first time it is needed.
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: "steward.lowspace", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
