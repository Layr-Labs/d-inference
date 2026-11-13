// Coordinator link liveness: how often the session pings the coordinator, and
// when a silent WebSocket counts as dead.

import Foundation

/// How often `sessionLoop` pings the coordinator, and how long the link may stay
/// silent before the provider declares it dead and reconnects.
///
/// A node that is hard-reset or a path that is dropped ends the WebSocket with
/// no TCP reset and no close frame; only silence shows it. The coordinator edge
/// answers WebSocket pings from its read loop, so a pong normally comes back in
/// milliseconds. An edge stall or heavy backpressure delays that pong. For this
/// reason every inbound frame counts as liveness (a pong, a ping from the
/// coordinator, any message), and the bound covers about three ping intervals.
/// A busy stream never trips it, and one late pong does not.
///
/// - `pingInterval`: the wait between two pings.
/// - `deadAfter`: no inbound frame for longer than this declares the link dead.
///   The ping task checks on each tick, so a silent link is declared dead
///   `deadAfter` to `deadAfter + pingInterval` after its last frame.
/// - `suspensionGap`: a tick that comes this much later than the one before it
///   means the process or the Mac was suspended (sleep). The provider reconnects
///   once at wake, because the coordinator has probably dropped the session.
///   A shorter late tick only restarts the silence window: the time when the
///   ping task could not ping is not counted as unanswered pings.
public struct CoordinatorLinkLiveness: Sendable, Equatable {
    public let pingInterval: Duration
    public let deadAfter: Duration
    public let suspensionGap: Duration

    /// Production uses the defaults; tests shorten them.
    public init(
        pingInterval: Duration = .seconds(2),
        deadAfter: Duration = .seconds(6),
        suspensionGap: Duration = .seconds(30)
    ) {
        precondition(pingInterval > .zero && pingInterval < deadAfter && deadAfter < suspensionGap,
                     "link liveness needs 0 < pingInterval < deadAfter < suspensionGap")
        self.pingInterval = pingInterval
        self.deadAfter = deadAfter
        self.suspensionGap = suspensionGap
    }
}

/// What one tick of the ping task decides about the link.
enum CoordinatorLinkVerdict: Equatable, Sendable {
    /// Send the next ping.
    case alive
    /// No inbound frame for longer than `deadAfter`: reconnect now.
    case dead
    /// The tick came `suspensionGap` or more late: the process was suspended.
    case suspended
}

/// The ping task's view of one session's link. It reads the time on the
/// continuous clock, which keeps counting while the Mac sleeps, so a sleep
/// shows as a late tick and a wall-clock change does not.
struct CoordinatorLinkWatch {
    let liveness: CoordinatorLinkLiveness
    private var lastTick: ContinuousClock.Instant
    /// Silence is counted from the later of this and the last inbound frame.
    private var silenceStart: ContinuousClock.Instant

    init(liveness: CoordinatorLinkLiveness, start: ContinuousClock.Instant) {
        self.liveness = liveness
        lastTick = start
        silenceStart = start
    }

    mutating func check(now: ContinuousClock.Instant,
                        lastInbound: ContinuousClock.Instant) -> CoordinatorLinkVerdict {
        let gap = now - lastTick
        lastTick = now
        if gap >= liveness.suspensionGap { return .suspended }
        if gap > liveness.deadAfter {
            // The ping task itself did not run for longer than the bound, so
            // the silence is ours, not the peer's. Ping now and judge from here.
            silenceStart = now
            return .alive
        }
        return now - max(lastInbound, silenceStart) > liveness.deadAfter ? .dead : .alive
    }
}
