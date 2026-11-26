// Coordinator link liveness: how often the session pings the coordinator, and
// when a silent WebSocket counts as dead.

import Foundation

/// How often `sessionLoop` pings the coordinator, and how long the link may stay
/// silent before the provider declares it dead and reconnects.
///
/// A node that is hard-reset or a path that is dropped ends the WebSocket with
/// no TCP reset and no close frame; only silence shows it. The coordinator edge
/// answers WebSocket pings from its read loop, so a pong normally comes back in
/// milliseconds. An edge stall or heavy backpressure delays that pong: the edge
/// writes a large request body in fragments under the connection's write lock,
/// a pong waits for the fragment being written, and the edge itself gives a
/// body up to `size / 2 MiB/s` (at least 5 s, at most 30 s) before it drops the
/// connection. For this reason every inbound frame counts as liveness
/// (a pong, a ping from the coordinator, any message), and the bound, 20 s,
/// is longer than the edge's own write budget for the largest request body
/// (about 10.5 s for 21 MiB). A busy stream never trips it, and nor do late
/// pongs behind a large body. A hard-reset node is still found in 20 to 22 s
/// (6 to 8 s with the former 6 s bound; 30 to 40 s with the 10 s pings and 30 s
/// pong timeout before it).
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
/// - `firstFrameGrace`: the bound before the coordinator's first frame on a new
///   connection, instead of `deadAfter`. The coordinator answers a connection
///   (and its pings) once it has registered the provider, which takes longer
///   when many providers reconnect at once; a fresh connection that waits in
///   that queue is not a dead link.
public struct CoordinatorLinkLiveness: Sendable, Equatable {
    public let pingInterval: Duration
    public let deadAfter: Duration
    public let suspensionGap: Duration
    public let firstFrameGrace: Duration

    /// Production uses the defaults; tests shorten them.
    public init(
        pingInterval: Duration = .seconds(2),
        // RED CONTROL, never merge: the former 6 s bound.
        deadAfter: Duration = .seconds(6),
        suspensionGap: Duration = .seconds(30),
        firstFrameGrace: Duration = .seconds(30)
    ) {
        precondition(pingInterval > .zero && pingInterval < deadAfter && deadAfter < suspensionGap,
                     "link liveness needs 0 < pingInterval < deadAfter < suspensionGap")
        precondition(firstFrameGrace >= deadAfter, "link liveness needs firstFrameGrace >= deadAfter")
        self.pingInterval = pingInterval
        self.deadAfter = deadAfter
        self.suspensionGap = suspensionGap
        self.firstFrameGrace = firstFrameGrace
    }
}

/// What one tick of the ping task decides about the link.
enum CoordinatorLinkVerdict: Equatable, Sendable {
    /// Send the next ping.
    case alive
    /// No inbound frame for longer than `deadAfter` (`firstFrameGrace` before
    /// the coordinator's first frame): reconnect now.
    case dead
    /// The tick came `suspensionGap` or more late: the process was suspended.
    case suspended
}

/// The ping task's view of one session's link. The caller gives it times on
/// the continuous clock, which keeps counting while the Mac sleeps, so a sleep
/// shows as a late tick and a wall-clock change does not.
struct CoordinatorLinkWatch {
    let liveness: CoordinatorLinkLiveness
    /// When the session's watch started; an inbound frame after it is the
    /// coordinator's first answer on this connection.
    private let start: ContinuousClock.Instant
    private var lastTick: ContinuousClock.Instant
    /// Silence is counted from the later of this and the last inbound frame.
    private var silenceStart: ContinuousClock.Instant

    init(liveness: CoordinatorLinkLiveness, start: ContinuousClock.Instant) {
        self.liveness = liveness
        self.start = start
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
        return now - max(lastInbound, silenceStart) > silenceBound(lastInbound: lastInbound) ? .dead : .alive
    }

    /// The silence that declares the link dead: `firstFrameGrace` until the
    /// coordinator's first frame on this connection, `deadAfter` after it.
    func silenceBound(lastInbound: ContinuousClock.Instant) -> Duration {
        lastInbound > start ? liveness.deadAfter : liveness.firstFrameGrace
    }
}

/// Private WebSocket close codes (RFC 6455: 4000-4999) the provider sends just
/// before it drops a link it judged dead, slept through or could no longer
/// keep up with, so the coordinator records why the session ended
/// (`ws_close_4001`, `ws_close_4002`, `ws_close_4003`) instead of a frame-less
/// read error. On a link that is really dead the frame is lost and
/// nothing changes.
enum CoordinatorLinkCloseCode: UInt16, Sendable {
    /// No inbound frame for longer than the bound (`CoordinatorLinkVerdict.dead`).
    case silentLink = 4001
    /// A ping tick `suspensionGap` or more late (`CoordinatorLinkVerdict.suspended`).
    case suspended = 4002
    /// Frames read and not yet handled past a limit (`CoordinatorInboundBacklog`).
    case inboundBacklog = 4003
}
