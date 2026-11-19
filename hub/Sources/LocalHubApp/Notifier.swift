import Foundation
import LocalHubCore
import UserNotifications

/// macOS notifications for long jobs. Only inside the bundled app (notifications need a bundle id).
enum Notifier {
    static var available: Bool { Bundle.main.bundleIdentifier != nil }
    /// Jobs quicker than this finish while the user is still looking; no banner.
    static let threshold: TimeInterval = 20

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func jobFinished(_ job: HubJob) {
        guard available, (job.duration ?? 0) >= threshold else { return }
        let content = UNMutableNotificationContent()
        switch job.status {
        case .completed:
            content.title = "\(job.capability.title) finished"
            content.body = "\(job.deviceName) · \(job.prompt)"
        case .failed:
            content.title = "\(job.capability.title) failed"
            content.body = job.error ?? job.prompt
        default:
            return
        }
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: job.id, content: content, trigger: nil))
    }

    static func notify(title: String, body: String, id: String = UUID().uuidString) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
