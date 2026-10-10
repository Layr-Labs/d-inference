import Foundation
import Darwin

/// The link is not ready for the rank this Mac would start, after waiting.
public struct ClusterLinkNotReady: Error, Equatable, CustomStringConvertible {
    public let device: String
    public let state: ClusterLinkReadinessState
    public let waitedSeconds: Int
    let guidance: String?

    public var description: String {
        "The cluster link on this Mac is not ready: \(device) is \(state.rawValue) after waiting \(waitedSeconds) s, "
            + "so the rank was not started (JACCL would refuse the device for want of an IPv4-mapped GID). "
            + (guidance ?? "`darkbloom cluster link` shows the port.")
    }
}

/// Before a rank starts, wait a bounded time for this Mac's cluster port to be
/// ready, instead of starting into JACCL's "No IPv4-mapped GID" refusal when
/// macOS is reconfiguring the port at that moment (twice on 2026-10-09 a run
/// started inside such a gap). The wait reads local state only, the same
/// readings `darkbloom cluster link` takes, without the network settings.
public enum ClusterLinkLaunchReadiness {
    /// Long enough for macOS to put a port's address back after it
    /// reconfigured the port, short against a model's startup allowance.
    public static let waitSeconds = 20
    static let pollIntervalSeconds = 1

    enum Decision: Equatable {
        case launch
        /// Look again after the poll interval.
        case wait
        case refuse(ClusterLinkReadinessState)
    }

    /// What to do with one reading `elapsedSeconds` into the wait.
    ///
    /// Ready: launch. A state that waiting cannot change (RDMA off or
    /// missing) refuses at once. A port that lacks its address or GID, or no
    /// active port, is waited for and then refused with that state. A reading
    /// that failed, or a device this Mac does not list, cannot say the link
    /// is unusable: after the wait the launch goes ahead and JACCL decides.
    static func decide(_ report: ClusterLinkReadinessReport, device: String, elapsedSeconds: Int,
                       limitSeconds: Int = waitSeconds) -> Decision {
        let state: ClusterLinkReadinessState
        switch report.state {
        case .rdmaDisabled, .rdmaUnavailable: return .refuse(report.state)
        case .probeFailed: state = .probeFailed
        default: state = report.devices.first { $0.device == device }?.verdict ?? .probeFailed
        }
        if state == .ready { return .launch }
        guard elapsedSeconds >= limitSeconds else { return .wait }
        return state == .probeFailed ? .launch : .refuse(state)
    }

    /// Blocking: at most `limitSeconds` plus one reading. Throws
    /// `ClusterLinkNotReady` when the port is known not to be usable.
    /// `uptimeNanoseconds` is the clock the wait is measured on, so a slow
    /// reading counts against it as well.
    static func waitForLink(device: String, limitSeconds: Int = waitSeconds,
                            inspect: () -> ClusterLinkReadinessReport, sleep: (Int) -> Void,
                            uptimeNanoseconds: () -> UInt64) throws {
        let start = uptimeNanoseconds()
        while true {
            let report = inspect()
            let elapsed = Int((uptimeNanoseconds() - start) / 1_000_000_000)
            switch decide(report, device: device, elapsedSeconds: elapsed, limitSeconds: limitSeconds) {
            case .launch:
                return
            case .refuse(let state):
                let guidance = report.devices.first { $0.device == device }?.guidance ?? state.guidance
                throw ClusterLinkNotReady(device: device, state: state, waitedSeconds: elapsed, guidance: guidance)
            case .wait:
                sleep(pollIntervalSeconds)
            }
        }
    }

    /// The live wait for the saved setup's device on this Mac.
    public static func waitForLink(device: String) throws {
        try waitForLink(device: device, inspect: { ClusterLinkReadinessProbe.inspectLocalLink(isolation: false) },
            sleep: { seconds in Darwin.sleep(UInt32(seconds)) },
            uptimeNanoseconds: { DispatchTime.now().uptimeNanoseconds })
    }
}
