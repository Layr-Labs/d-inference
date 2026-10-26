import Foundation

/// When to re-register a connection the coordinator keeps refusing to route.
///
/// A new registration starts a new coordinator verification session. That
/// clears coordinator-side states only a reconnect clears: a verification
/// session that stopped after an unclassified failure, an hourly retry
/// backoff, and a connection that never got a status. It cannot fix a cause
/// outside the connection (an old macOS, a locked keychain, a rejected device
/// login), so attempts back off and never interrupt accepted work. The
/// per-process jitter spreads a fleet that lost authorization at once, such
/// as during an Apple or coordinator outage.
public enum UnauthorizedConnectionRecovery {
    /// Longer than the coordinator's one- and five-minute verification retries.
    public static let unauthorizedThreshold: TimeInterval = 15 * 60
    /// Added once per process to the threshold: 0 ..< this.
    public static let thresholdJitter: TimeInterval = 15 * 60
    public static let firstRetryInterval: TimeInterval = 30 * 60
    public static let maximumRetryInterval: TimeInterval = 4 * 3600

    /// `attempts` counts re-registrations since the connection was last
    /// authorized; the wait between them doubles up to the maximum.
    public static func shouldReconnect(
        unauthorizedSince: Double?, lastReconnectAt: Double?, attempts: Int,
        workInProgress: Bool, jitter: TimeInterval = 0, now: Double
    ) -> Bool {
        guard let unauthorizedSince, !workInProgress,
              now - unauthorizedSince >= unauthorizedThreshold + jitter else { return false }
        if let lastReconnectAt, now - lastReconnectAt < retryInterval(afterAttempts: attempts) { return false }
        return true
    }

    public static func retryInterval(afterAttempts attempts: Int) -> TimeInterval {
        let doublings = min(max(attempts - 1, 0), 8)
        return min(firstRetryInterval * pow(2, Double(doublings)), maximumRetryInterval)
    }

    /// Whether the coordinator's latest status says this connection may not be
    /// routed: an explicit `none` path, an expired App Attest lease, or no
    /// status long after registering. A status without an authorization object
    /// (a coordinator without App Attest serving) is not judged.
    public static func connectionLacksAuthorization(
        connectedAt: Double, trust: DaemonState.Trust?, now: Double
    ) -> Bool {
        guard let trust else { return now - connectedAt >= ServingReadiness.statusGraceSeconds }
        if trust.status == "untrusted" || trust.status == "offline" { return true }
        guard let authorization = trust.authorization else { return false }
        return !authorization.hasCurrentAppAttestAuthorization(now: now) && authorization.path != "legacy"
    }
}
