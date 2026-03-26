/// NotificationManager — macOS system notifications for key provider events.
///
/// Sends notifications for:
///   - Provider went offline unexpectedly
///   - Security status changed
///   - First inference request completed
///   - Earnings milestone reached

import Foundation
import UserNotifications

@MainActor
final class NotificationManager: ObservableObject {

    @Published var isAuthorized = false

    /// Request notification permission on first launch.
    func requestAuthorization() {
        // UNUserNotificationCenter crashes in SPM test runner and CLI contexts
        // where there's no bundle proxy. Guard against that.
        guard Bundle.main.bundleIdentifier != nil else { return }

        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { [weak self] granted, _ in
            Task { @MainActor in
                self?.isAuthorized = granted
            }
        }
    }

    /// Notify that the provider went offline unexpectedly.
    func notifyProviderOffline() {
        send(
            title: "Provider Offline",
            body: "The inference provider stopped unexpectedly. Open DGInf to restart.",
            identifier: "provider-offline"
        )
    }

    /// Notify that the provider started serving.
    func notifyProviderOnline(model: String) {
        send(
            title: "Provider Online",
            body: "Now serving \(model). Your Mac is earning while idle.",
            identifier: "provider-online"
        )
    }

    /// Notify a security posture change.
    func notifySecurityChange(_ message: String) {
        send(
            title: "Security Alert",
            body: message,
            identifier: "security-change"
        )
    }

    /// Notify an inference completion.
    func notifyInferenceCompleted(requestCount: Int) {
        // Only notify on milestones (10, 50, 100, 500, 1000...)
        let milestones = [10, 50, 100, 500, 1000, 5000, 10000]
        guard milestones.contains(requestCount) else { return }

        send(
            title: "Milestone Reached",
            body: "You've served \(requestCount) inference requests!",
            identifier: "milestone-\(requestCount)"
        )
    }

    // MARK: - Internal

    private func send(title: String, body: String, identifier: String) {
        guard isAuthorized, Bundle.main.bundleIdentifier != nil else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request)
    }
}
