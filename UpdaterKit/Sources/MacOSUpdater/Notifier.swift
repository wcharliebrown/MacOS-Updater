import Foundation
import UserNotifications

/// Local notifications when new updates appear.
///
/// Notification authorisation requires a signed bundle; on an unsigned build the
/// request simply fails and the app carries on without notifying.
enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge]) { _, error in
                if let error { NSLog("Notification authorisation failed: \(error)") }
            }
    }

    static func notify(newCount: Int, total: Int) {
        let content = UNMutableNotificationContent()
        content.title = newCount == 1 ? "1 new update available" : "\(newCount) new updates available"
        content.body = total == 1 ? "1 app is out of date." : "\(total) apps are out of date."
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
