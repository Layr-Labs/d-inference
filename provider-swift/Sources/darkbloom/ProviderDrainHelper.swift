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
    timeout: TimeInterval = 600.0
) async -> Bool {
    guard LaunchAgent.isAnySupportedLabelLoaded() else { return false }

    // Authoritative drain target: the PID launchd reports for the loaded
    // service. This ties the drain to the launchd-managed daemon, so a
    // standalone `start --local` server — which also writes the shared
    // `~/.darkbloom/provider.pid` lock file — is never the one we signal on
    // `stop`/`restart`/replacement `start`.
    guard let pid = LaunchAgent.loadedServicePID(), pid > 0, ProcessLifecycle.processIsAlive(pid) else {
        // The job is loaded but launchd has no live PID for it (e.g. installed
        // but not yet kickstarted). Fall back to the launchd-level path.
        return false
    }

    // Read the daemon state for the user-facing in-flight count. If the freshest
    // state describes a *different* process than the one launchd is running, the
    // state file is stale/foreign — don't risk a confusing message, but still
    // drain launchd's actual PID.
    let state = DaemonStateFile.read()
    let now = Date().timeIntervalSince1970
    let freshState: DaemonState? = {
        guard let state, !state.isStale(now: now) else { return nil }
        return state.pid == pid ? state : nil
    }()

    let requestCount = freshState?.inflightRequestCount ?? (freshState?.inferenceActive == true ? 1 : 0)
    if requestCount > 0 {
        let plural = requestCount == 1 ? "" : "s"
        print("Provider is currently serving \(requestCount) request\(plural). Waiting up to \(Int(timeout))s for them to finish before \(action.verb)...")
    } else if freshState?.inferenceActive == true {
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
