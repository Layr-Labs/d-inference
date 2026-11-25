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
    /// Reason of that close frame, when the provider read it from the frame's
    /// payload (`NWProtocolWebSocket.Metadata.sentCloseReason`). Nil when there
    /// is no close frame, no reason, or a code that Network.framework named.
    var closeReason: String? = nil
}

/// Chooses the range that the wait before the next coordinator connection
/// attempt is drawn from. The caller draws at random, so that providers that
/// lost their sockets at the same time do not reconnect in lockstep.
///
/// - A session that stayed open for `stableSessionDuration` or more resets the
///   backoff first. A long session that drops starts again from the shortest
///   wait, independent of the drops before it.
/// - A close frame with code 1012 and the reason `planned move` gives 0 s and
///   does not grow the backoff. Only the coordinator's close pacer sends it: it
///   closes the sockets of a planned event (an edge restart, a coordinator stop,
///   a move of a pair to its home) at a bounded rate, pair members first, so the
///   provider reconnects at once and the coordinator still registers the fleet
///   at its own pace.
/// - Any other close frame with code 1001 (going away) or 1012 (service restart) gives
///   0 to 15 s and does not grow the backoff. The server side sends these codes
///   to every provider at once (a proxy that reloads, a coordinator that stops
///   or restarts), so the next attempt can succeed, but a fleet that reconnects
///   in the same second registers slower than its links tolerate. Spread over
///   15 s, the reconnects of a fleet of up to about 1,400 providers stay below
///   a coordinator that registers 95 per second; a larger fleet also relies on
///   `CoordinatorLinkLiveness.firstFrameGrace` while it waits for its answer.
/// - Any other end of a stable session gives 0 to 0.25 s and does not grow the
///   backoff. A link that was healthy until it dropped (a dead link that the
///   ping task found, a reset, a close) most likely reconnects at once, for
///   example to another coordinator node. The small range keeps a fleet that
///   dropped together from reconnecting in the same instant.
/// - Every other end takes the next exponential backoff range and grows it, so
///   repeated failures still back off.
public struct CoordinatorReconnectPolicy: Sendable {
    /// 1001 (going away) and 1012 (service restart).
    static let fleetCloseCodes: Set<UInt16> = [1001, 1012]
    /// The close frame of a planned close that the coordinator paces: code 1012
    /// with this exact reason. The provider reconnects without a wait.
    static let plannedCloseCode: UInt16 = 1012
    static let plannedCloseReason = "planned move"
    static let plannedCloseRange: ClosedRange<TimeInterval> = 0...0
    static let stableSessionRetryRange: ClosedRange<TimeInterval> = 0...0.25

    let stableSessionDuration: Duration
    let fleetCloseDelayRange: ClosedRange<TimeInterval>
    private var backoff = ExponentialBackoff(base: 1.0, max: 30.0)

    /// Production uses the defaults; tests shorten them.
    public init(
        stableSessionDuration: Duration = .seconds(60),
        fleetCloseDelayRange: ClosedRange<TimeInterval> = 0...15
    ) {
        self.stableSessionDuration = stableSessionDuration
        self.fleetCloseDelayRange = fleetCloseDelayRange
    }

    /// Returns the range of the wait after `end` and updates the backoff.
    mutating func nextDelayRange(after end: CoordinatorSessionEnd) -> ClosedRange<TimeInterval> {
        let stable = end.openDuration.map { $0 >= stableSessionDuration } ?? false
        if stable { backoff.reset() }
        if end.closeCode == Self.plannedCloseCode, end.closeReason == Self.plannedCloseReason {
            return Self.plannedCloseRange
        }
        if let code = end.closeCode, Self.fleetCloseCodes.contains(code) {
            return fleetCloseDelayRange
        }
        return stable ? Self.stableSessionRetryRange : backoff.nextDelayRange()
    }

    /// Starts the next wait from the shortest backoff, as after a session that
    /// ended without an error.
    mutating func reset() {
        backoff.reset()
    }
}
