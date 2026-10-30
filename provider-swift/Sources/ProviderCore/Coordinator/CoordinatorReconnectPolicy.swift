// Coordinator reconnect policy: the wait before the next connection attempt,
// chosen from how the previous attempt ended.

import Foundation

/// How one coordinator connection attempt ended, as the reconnect policy reads it.
struct CoordinatorSessionEnd: Equatable, Sendable {
    /// How long the session stayed open after its `register` frame was sent.
    /// Nil when the attempt ended before that, for example a refused upgrade.
    var openDuration: Duration?
    /// Code of the WebSocket close frame that the coordinator side sent. Nil
    /// when the connection ended without one: a transport close, a pong
    /// timeout, a detected suspension or a close that the provider started.
    var closeCode: UInt16?
}

/// Chooses the range that the wait before the next coordinator connection
/// attempt is drawn from. The caller draws at random, so that providers that
/// lost their sockets at the same time do not reconnect in lockstep.
///
/// - A session that stayed open for `stableSessionDuration` or more resets the
///   backoff first. A long session that drops starts again from the shortest
///   wait, independent of the drops before it.
/// - A close frame with code 1012 (service restart) gives 0 to 1 s and does not
///   grow the backoff: the service behind the socket restarts, so the next
///   attempt can succeed at once.
/// - Every other end takes the next exponential backoff range and grows it.
public struct CoordinatorReconnectPolicy: Sendable {
    static let serviceRestartCloseCode: UInt16 = 1012
    static let serviceRestartDelayRange: ClosedRange<TimeInterval> = 0...1

    let stableSessionDuration: Duration
    private var backoff = ExponentialBackoff(base: 1.0, max: 30.0)

    /// Production uses the default; tests shorten `stableSessionDuration`.
    public init(stableSessionDuration: Duration = .seconds(60)) {
        self.stableSessionDuration = stableSessionDuration
    }

    /// Returns the range of the wait after `end` and updates the backoff.
    mutating func nextDelayRange(after end: CoordinatorSessionEnd) -> ClosedRange<TimeInterval> {
        if let openDuration = end.openDuration, openDuration >= stableSessionDuration {
            backoff.reset()
        }
        if end.closeCode == Self.serviceRestartCloseCode {
            return Self.serviceRestartDelayRange
        }
        return backoff.nextDelayRange()
    }

    /// Starts the next wait from the shortest backoff, as after a session that
    /// ended without an error.
    mutating func reset() {
        backoff.reset()
    }
}
