import Foundation
import UserNotifications

/// Local notifications for a recording that has gone quiet or run long. Inert unless running from an
/// app bundle, because UserNotifications is unavailable to a bare command-line binary.
@MainActor
final class RecordingNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called with the id of the recording the tapped notification belongs to.
    var onStop: ((String?) -> Void)?
    var onKeep: ((String?) -> Void)?
    private static let prefixes = ["quiet-", "long-"]
    private let available = Bundle.main.bundleURL.pathExtension == "app"
    private var prepared = false
    private var center: UNUserNotificationCenter? { available ? .current() : nil }

    /// Registers the Stop / Keep buttons and asks for permission once.
    func prepare() {
        guard let center, !prepared else { return }
        prepared = true
        center.delegate = self
        let stop = UNNotificationAction(identifier: "stop", title: "Stop recording", options: [])
        let keep = UNNotificationAction(identifier: "keep", title: "Keep recording", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "quiet", actions: [stop, keep], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "long", actions: [stop], intentIdentifiers: [], options: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        clearActionNotices()   // Buttons left over from an earlier launch must not linger.
    }

    func postQuiet(recording: UUID, minutes: Int, stopsInMinutes: Int?) {
        let tail = stopsInMinutes.map { "It will stop by itself in \($0) minutes unless you keep it going." } ?? "Stop it if the meeting is over."
        post(id: "quiet-\(recording)", recording: recording, category: "quiet", title: "Still recording?",
             body: "No audio for \(minutes) minutes. \(tail)")
    }

    func postLong(recording: UUID, hours: Int) {
        post(id: "long-\(recording)", recording: recording, category: "long", title: "Recording for \(hours) hours",
             body: "Audio is still coming in. Stop when the meeting is over.")
    }

    func postStopped(recording: UUID, quietMinutes: Int) {
        post(id: "stopped-\(recording)", recording: recording, category: nil, title: "Recording stopped",
             body: "No audio for \(quietMinutes) minutes. Everything up to then is saved and is being processed.")
    }

    /// Withdraws every reminder that has buttons, for any recording: used when one ends or the app starts.
    func clearActionNotices() {
        guard let center else { return }
        center.getDeliveredNotifications { delivered in
            let ids = delivered.map(\.request.identifier).filter { id in Self.prefixes.contains { id.hasPrefix($0) } }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
        center.getPendingNotificationRequests { pending in
            let ids = pending.map(\.identifier).filter { id in Self.prefixes.contains { id.hasPrefix($0) } }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    /// Withdraws only the quiet reminder, when sound resumes or the user chooses to keep recording.
    func clearQuiet(recording: UUID?) {
        guard let center, let recording else { return }
        center.removeDeliveredNotifications(withIdentifiers: ["quiet-\(recording)"])
        center.removePendingNotificationRequests(withIdentifiers: ["quiet-\(recording)"])
    }

    private func post(id: String, recording: UUID, category: String?, title: String, body: String) {
        guard let center, prepared else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        content.userInfo = ["recording": recording.uuidString]
        if let category { content.categoryIdentifier = category }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        completion([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completion: @escaping () -> Void) {
        let action = response.actionIdentifier
        let recording = response.notification.request.content.userInfo["recording"] as? String
        completion()
        Task { @MainActor in
            if action == "stop" { onStop?(recording) } else if action == "keep" { onKeep?(recording) }
        }
    }
}
