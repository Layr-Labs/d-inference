import Foundation
import DarkbloomClusterProtocol

/// The peer-liveness rule of one link control edge: when the other member's
/// connection is gone and does not come back in the time a live member needs
/// to come back, that member is lost, and the sessions it served are told at
/// once, with the reason.
///
/// The owner's rule (oMLX `cluster/liveness.py`: a peer that misses its
/// heartbeats is a stated peer loss, not a stall) ported to Darkbloom's link
/// control channel, which already detects a dead connection (EOF/reset from
/// the peer, or `silenceTimeout` without a frame) and resumes a live one (the
/// dialling member re-dials with backoff up to `reconnectMaximumDelay`, each
/// attempt bounded by `connectTimeout` and `handshakeTimeout`). What it did
/// not do is decide when a connection that did not resume means the member is
/// gone: a session waited for proofs that could never arrive, and the request
/// in flight hung until a rank's own progress limit.
///
/// Every bound is the edge's own link timing; nothing is tuned for a Mac or a
/// model. The window never exceeds the rank lease's TTL: by then the follower
/// has fenced its rank by its own lease anyway.
///
/// - A planned rollover (`rekey`, `superseded`) or this side's own shutdown is
///   not a loss.
/// - The peer closed the connection (`peerClosed`: an EOF or reset from its
///   side, which a killed or exiting process produces): a live member is
///   already re-dialling, so the window is one re-dial at the longest backoff.
/// - This side noticed first (`peerSilent`, a transport or write failure, a
///   protocol or authentication failure): the peer may notice only at its own
///   silence bound, so that bound comes first.
/// - A resumed connection (same peer incarnation) ends the wait. A member that
///   came back as a new process (`peerRestarted`) is a loss at once; the
///   router and the server already handle that event themselves.
public final class ClusterLinkPeerLiveness: @unchecked Sendable {
    public typealias Schedule = @Sendable (_ afterNanoseconds: UInt64, _ work: @escaping @Sendable () -> Void) -> Void

    /// How long a live member needs to resume after `reason`; nil when the
    /// disconnect is not a loss at all.
    public static func resumeWindowNanoseconds(after reason: ClusterLinkControlDisconnect,
                                               limits: ClusterLinkControlLimits) -> UInt64? {
        let redial = limits.reconnectMaximumDelay.clusterLinkNanoseconds
            &+ limits.connectTimeout.clusterLinkNanoseconds &+ limits.handshakeTimeout.clusterLinkNanoseconds
        let window: UInt64
        switch reason {
        case .rekey, .superseded, .localShutdown: return nil
        case .peerClosed: window = redial
        case .peerSilent, .transportError, .writeTimeout, .protocolViolation, .authenticationFailed:
            window = limits.silenceTimeout.clusterLinkNanoseconds &+ redial
        }
        return min(window, ClusterWorkerLease.ttlNanoseconds)
    }

    /// The reason stated to the sessions, plain ASCII.
    public static func lossReason(_ reason: ClusterLinkControlDisconnect, windowNanoseconds: UInt64) -> String {
        let seconds = String(format: "%.1f", Double(windowNanoseconds) / 1e9)
        switch reason {
        case .peerClosed:
            return "the other member closed the link control connection (its process ended or stopped) and did not reconnect within \(seconds) s"
        default:
            return "the link control connection to the other member was lost (\(reason.rawValue)) and did not resume within \(seconds) s"
        }
    }

    private let limits: ClusterLinkControlLimits
    private let schedule: Schedule
    private let lost: @Sendable (String) -> Void
    private let lock = NSLock()
    /// Moves on every connect and disconnect: a timer fires only for the
    /// disconnect that armed it.
    private var generation: UInt64 = 0
    private var down = false
    private var losses = 0

    public init(limits: ClusterLinkControlLimits = .init(),
                schedule: @escaping Schedule = { delay, work in
                    DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(min(delay, UInt64(Int.max)))), execute: work)
                },
                lost: @escaping @Sendable (String) -> Void) {
        self.limits = limits; self.schedule = schedule; self.lost = lost
    }

    /// Losses stated so far (checks and diagnostics).
    public var lossCount: Int { lock.withLock { losses } }

    public func handle(_ event: ClusterLinkControlEvent) {
        switch event {
        case .connected:
            lock.withLock { generation &+= 1; down = false }
        case .disconnected(_, let reason):
            guard let window = Self.resumeWindowNanoseconds(after: reason, limits: limits) else { return }
            let armed = lock.withLock { () -> UInt64 in generation &+= 1; down = true; return generation }
            let message = Self.lossReason(reason, windowNanoseconds: window)
            schedule(window) { [weak self] in self?.expire(armed, message) }
        default: break
        }
    }

    private func expire(_ armed: UInt64, _ message: String) {
        let fire = lock.withLock { () -> Bool in
            guard down, generation == armed else { return false }
            losses += 1; return true
        }
        if fire { lost(message) }
    }
}
