import Foundation
import UserNotifications
import os.log

private let logger = Logger(subsystem: "com.jacobcoffee.loopbacker", category: "Notifications")

/// Posts user-visible notifications for changes the user didn't directly request: a source
/// rebinding to a fallback device, or a rule switching scenes. No windows, no focus stealing —
/// `UNUserNotificationCenter` banners only.
@MainActor
final class SceneNotifier {
    static let shared = SceneNotifier()

    private var authorized = false
    private var requested = false

    private init() {}

    private func ensureAuthorized() async -> Bool {
        if authorized { return true }
        guard !requested else { return authorized }
        requested = true
        do {
            authorized = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
        } catch {
            logger.warning("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
        }
        return authorized
    }

    private func post(title: String, body: String) {
        Task {
            guard await ensureAuthorized() else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                logger.warning("Failed to post notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// A source rebound from one device to another (fallback list, or a name-matched recovery).
    /// `sourceName` is the source's label, which matches the device it was bound to.
    func deviceFallback(sourceName: String, toDeviceName: String) {
        post(title: "Loopbacker switched devices", body: "\(sourceName) is gone — Loopbacker switched to \(toDeviceName).")
    }

    /// An automation rule (or the fallback) loaded a scene on its own.
    func sceneApplied(sceneName: String, reason: String) {
        post(title: "Loopbacker switched scenes", body: "Loaded “\(sceneName)” — \(reason).")
    }
}
