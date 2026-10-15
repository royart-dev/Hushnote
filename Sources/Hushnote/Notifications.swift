import Foundation
import UserNotifications

/// Local notifications for a recording that has gone quiet or run long. Inert unless running from an
/// app bundle, because UserNotifications is unavailable to a bare command-line binary.
@MainActor
final class RecordingNotifier: NSObject, UNUserNotificationCenterDelegate {
    var onStop: (() -> Void)?
    var onKeep: (() -> Void)?
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
    }

    func postQuiet(minutes: Int, stopsInMinutes: Int?) {
        let tail = stopsInMinutes.map { "It will stop by itself in \($0) minutes unless you keep it going." } ?? "Stop it if the meeting is over."
        post(id: "quiet", category: "quiet", title: "Still recording?",
             body: "No audio for \(minutes) minutes. \(tail)")
    }

    func postLong(hours: Int) {
        post(id: "long", category: "long", title: "Recording for \(hours) hours",
             body: "Audio is still coming in. Stop when the meeting is over.")
    }

    func postStopped(quietMinutes: Int) {
        post(id: "stopped", category: nil, title: "Recording stopped",
             body: "No audio for \(quietMinutes) minutes. Everything up to then is saved and is being processed.")
    }

    func clearQuiet() {
        center?.removeDeliveredNotifications(withIdentifiers: ["quiet"])
        center?.removePendingNotificationRequests(withIdentifiers: ["quiet"])
    }

    private func post(id: String, category: String?, title: String, body: String) {
        guard let center, prepared else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
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
        completion()
        Task { @MainActor in
            if action == "stop" { onStop?() } else if action == "keep" { onKeep?() }
        }
    }
}
