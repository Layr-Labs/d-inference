import Foundation

/// The supervisor waits for this Mac's cluster port before it lets a member
/// register, so the coordinator never forms a pair one side of which cannot
/// reach the link (after a reboot macOS brings the Thunderbolt port and its
/// address up late, and the root keeper puts the address back on its own
/// schedule). The member's own 20 s launch wait (`ClusterLinkLaunchReadiness`)
/// still guards each rank start; this gate is the unbounded, supervised wait
/// in front of it.
public enum ClusterMemberLinkGate {
    public enum Decision: Equatable, Sendable {
        /// Start the member.
        case ready
        /// Look again after `recheckSeconds`; the port is coming up or lacks
        /// its address, which time (or the keeper) fixes.
        case wait(ClusterLinkReadinessState)
        /// Waiting will not fix this (RDMA off or absent): look again slowly
        /// and keep saying what the operator must do.
        case blocked(ClusterLinkReadinessState)
        /// The readings keep failing; start anyway and let the rank's own
        /// launch check and JACCL decide, as `ClusterLinkLaunchReadiness` does.
        case proceedUnverified
    }

    public static let recheckSeconds = 5
    public static let blockedRecheckSeconds = 60
    /// Failed readings for this long stop blocking a start.
    public static let unverifiedAfterSeconds = 60

    /// `machine` is the whole-Mac verdict, `device` the verdict for the saved
    /// setup's RDMA device (nil when this Mac does not list it).
    public static func decide(machine: ClusterLinkReadinessState, device: ClusterLinkReadinessState?,
                              probeFailingForSeconds: Int) -> Decision {
        switch machine {
        case .rdmaDisabled, .rdmaUnavailable:
            return .blocked(machine)
        default:
            break
        }
        let state: ClusterLinkReadinessState = machine == .probeFailed ? .probeFailed : (device ?? .probeFailed)
        switch state {
        case .ready:
            return .ready
        case .probeFailed:
            return probeFailingForSeconds >= unverifiedAfterSeconds ? .proceedUnverified : .wait(.probeFailed)
        case .rdmaDisabled, .rdmaUnavailable:
            return .blocked(state)
        case .noActivePort, .portWithoutIPv4Address, .portBridgedWithoutAddress, .gidNotPublished:
            return .wait(state)
        }
    }

    /// Log a waiting state at most this often, so a Mac waiting for its cable
    /// all night writes a line a minute, not one every five seconds.
    public static func shouldLog(state: ClusterLinkReadinessState, previous: ClusterLinkReadinessState?,
                                 secondsSinceLastLog: Double) -> Bool {
        state != previous || secondsSinceLastLog >= 60
    }
}
