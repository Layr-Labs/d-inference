import Foundation
import ProviderCore

/// Human-readable action name used in user-facing drain messages.
enum DrainAction: Sendable {
    case stop
    case restart
    case startReplace

    var verb: String {
        switch self {
        case .stop: return "stopping"
        case .restart: return "restarting"
        case .startReplace: return "replacing the running service"
        }
    }
}

/// Ask a running provider daemon to drain in-flight requests and exit gracefully
/// before the caller manipulates its launchd job.
///
/// Reads the daemon PID from `DaemonStateFile`, sends `SIGTERM`, and waits up to
/// `timeout` for the process to exit. If the daemon reports active inference,
/// the user is told to wait. On timeout the daemon is force-killed and a warning
/// is printed.
///
/// - Parameters:
///   - action: Describes the operation that will happen after the drain, for
///     user-facing messages.
///   - timeout: Seconds to wait after `SIGTERM` before escalating to `SIGKILL`.
/// - Returns: `true` if a live daemon was found and signalled; `false` if there
///   was no loaded service or no live PID to drain (caller should fall back to
///   its normal launchd path).
func drainRunningProvider(
    action: DrainAction,
    timeout: TimeInterval = 120.0
) async -> Bool {
    guard LaunchAgent.isAnySupportedLabelLoaded() else { return false }

    let state = DaemonStateFile.read()
    let now = Date().timeIntervalSince1970
    let pid: Int32?
    if let state, !state.isStale(now: now), ProcessLifecycle.processIsAlive(state.pid) {
        pid = state.pid
    } else {
        pid = nil
    }

    guard let pid else {
        // launchd thinks the job is loaded but we have no trustworthy live PID.
        // Fall back to the launchd-level stop/restart path.
        return false
    }

    let requestCount = state?.inflightRequestCount ?? 0
    if requestCount > 0 {
        let plural = requestCount == 1 ? "" : "s"
        print("Provider is currently serving \(requestCount) request\(plural). Waiting up to \(Int(timeout))s for them to finish before \(action.verb)...")
    } else if state?.inferenceActive == true {
        print("Provider is currently serving requests. Waiting up to \(Int(timeout))s for them to finish before \(action.verb)...")
    }

    let outcome = await ProcessLifecycle.stopProcessGracefully(pid: pid, timeout: timeout)

    switch outcome {
    case .notRunning:
        return false
    case .stoppedGracefully:
        return true
    case .forceKilled:
        print("Warning: provider did not stop within \(Int(timeout))s; force-killing before \(action.verb).")
        return true
    }
}
