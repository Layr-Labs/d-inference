import Foundation

/// When to re-register a connection the coordinator keeps refusing to route.
/// "Refusing" is the blocked `ServingReadiness` verdict that `status` and
/// `doctor` show, so only current evidence counts: a refusal the coordinator
/// stopped repeating does not.
///
/// A new registration starts a new coordinator verification session. That
/// clears coordinator-side states only a reconnect clears: a verification
/// session that stopped after an unclassified failure, an hourly retry
/// backoff, and a connection that never got a status. It cannot fix a cause
/// outside the connection (an old macOS, a locked keychain, a rejected device
/// login), so attempts back off and wait until the provider is idle. The
/// per-process jitter spreads a fleet that lost authorization at once, such
/// as during an Apple or coordinator outage.
enum UnauthorizedConnectionRecovery {
    /// Longer than the coordinator's 1-, 5- and 10-minute verification retries.
    static let unauthorizedThreshold: TimeInterval = 15 * 60
    /// Added once per process to the threshold: 0 ..< this.
    static let thresholdJitter: TimeInterval = 15 * 60
    static let firstRetryInterval: TimeInterval = 30 * 60
    static let maximumRetryInterval: TimeInterval = 4 * 3600

    /// `attempts` counts re-registrations since the connection was last
    /// authorized; the wait between them doubles up to the maximum.
    static func shouldReconnect(
        unauthorizedSince: Double?, lastReconnectAt: Double?, attempts: Int,
        busy: Bool, jitter: TimeInterval = 0, now: Double
    ) -> Bool {
        guard let unauthorizedSince, !busy,
              now - unauthorizedSince >= unauthorizedThreshold + jitter else { return false }
        if let lastReconnectAt, now - lastReconnectAt < retryInterval(afterAttempts: attempts) { return false }
        return true
    }

    static func retryInterval(afterAttempts attempts: Int) -> TimeInterval {
        let doublings = min(max(attempts - 1, 0), 8)
        return min(firstRetryInterval * pow(2, Double(doublings)), maximumRetryInterval)
    }
}
