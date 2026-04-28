/// IdleDetector — Monitors user keyboard/mouse activity.
///
/// Darkbloom should only serve inference when the user isn't actively using
/// their Mac. This class polls the system's idle time (seconds since last
/// keyboard/mouse event) on a 10-second interval and publishes whether
/// the user is idle.
///
/// The idle timeout is configurable (default 5 minutes). When the user
/// transitions between active and idle, StatusViewModel observes the
/// change and pauses/resumes the provider accordingly.
///
/// Implementation note:
///   Uses `CGEventSource.secondsSinceLastEventType(.hidSystemState, ...)`
///   which requires no special permissions (unlike accessibility APIs).
///   The `CGEventType(rawValue: ~0)!` value acts as a wildcard for any
///   input event type.

import Combine
import CoreGraphics
import Foundation

/// Polls system idle time and publishes user idle state.
///
/// The timer fires every 10 seconds and checks seconds since last
/// keyboard/mouse input. When idle time exceeds `idleTimeoutSeconds`,
/// `isUserIdle` flips to true.
@MainActor
final class IdleDetector: ObservableObject {

    /// Whether the user is currently idle (no keyboard/mouse input
    /// for longer than `idleTimeoutSeconds`).
    @Published var isUserIdle = false

    /// How many seconds of inactivity before the user is considered idle.
    /// Default: 300 seconds (5 minutes).
    var idleTimeoutSeconds: TimeInterval = 300

    private var timer: Timer?

    /// Start polling for idle state every 10 seconds.
    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkIdleState()
            }
        }
        // Check immediately
        checkIdleState()
    }

    /// Stop polling.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Query the system for seconds since last input event and update state.
    private func checkIdleState() {
        // CGEventType(rawValue: ~0) matches any input event type (keyboard, mouse, etc.)
        // .hidSystemState gives system-wide idle time without needing accessibility permissions
        let idleTime = CGEventSource.secondsSinceLastEventType(
            .hidSystemState,
            eventType: CGEventType(rawValue: ~0)!
        )
        isUserIdle = idleTime >= idleTimeoutSeconds
    }
}
