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

    /// Notify an inference completion with milestone celebrations.
    func notifyInferenceCompleted(requestCount: Int) {
        if requestCount == 1 {
            send(
                title: "First Inference Served!",
                body: "Your Mac just served its first AI request. You're earning now.",
                identifier: "milestone-first"
            )
            return
        }

        let milestones = [10, 50, 100, 500, 1000, 5000, 10000, 50000, 100000]
        guard milestones.contains(requestCount) else { return }

        let formatted = requestCount >= 1000
            ? String(format: "%.0fK", Double(requestCount) / 1000)
            : "\(requestCount)"
        send(
            title: "\(formatted) Requests Served!",
            body: "Your Mac has served \(formatted) inference requests. Keep it up!",
            identifier: "milestone-\(requestCount)"
        )
    }

    /// Notify earnings milestones in dollars.
    func notifyEarningsMilestone(_ amount: Double) {
        let milestones: [Double] = [1, 5, 10, 25, 50, 100, 250, 500, 1000]
        guard milestones.contains(amount) else { return }

        send(
            title: "You've earned $\(Int(amount))!",
            body: "Your Mac has earned $\(Int(amount)) serving private inference.",
            identifier: "earnings-\(Int(amount))"
        )
    }

    /// Notify token generation milestones.
    func notifyTokenMilestone(_ count: Int) {
        let milestones = [100_000, 1_000_000, 10_000_000, 100_000_000]
        guard milestones.contains(count) else { return }

        let formatted: String
        if count >= 1_000_000 {
            formatted = String(format: "%.0fM", Double(count) / 1_000_000)
        } else {
            formatted = String(format: "%.0fK", Double(count) / 1_000)
        }
        send(
            title: "\(formatted) Tokens Generated!",
            body: "Your Mac has generated \(formatted) tokens of AI inference.",
            identifier: "tokens-\(count)"
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
