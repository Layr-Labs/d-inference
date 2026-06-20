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

    // Authoritative drain targets: the PIDs launchd reports for the loaded
    // service label(s). This ties the drain to the launchd-managed daemon(s), so
    // a standalone `start --local` server — which also writes the shared
    // `~/.darkbloom/provider.pid` lock file — is never the one we signal on
    // `stop`/`restart`/replacement `start`. During an upgrade both the canonical
    // and a legacy job can be loaded; the launchd stop/replace paths unload every
    // supported label, so we must drain all of them.
    let pids = LaunchAgent.loadedServicePIDs().filter { $0 > 0 && ProcessLifecycle.processIsAlive($0) }
    guard !pids.isEmpty else {
        // The job is loaded but launchd has no live PID for it (e.g. installed
        // but not yet kickstarted). Fall back to the launchd-level path.
        return false
    }

    // Read the daemon state for the user-facing in-flight count. The state file
    // is a single file (with multiple daemons it reflects whichever wrote last);
    // only trust it for messaging when its PID is one we're about to drain.
    let state = DaemonStateFile.read()
    let now = Date().timeIntervalSince1970
    let freshState: DaemonState? = {
        guard let state, !state.isStale(now: now) else { return nil }
        return pids.contains(state.pid) ? state : nil
    }()

    let requestCount = freshState?.inflightRequestCount ?? (freshState?.inferenceActive == true ? 1 : 0)
    if requestCount > 0 {
        let plural = requestCount == 1 ? "" : "s"
        print("Provider is currently serving \(requestCount) request\(plural). Waiting up to \(Int(timeout))s for them to finish before \(action.verb)...")
    } else if freshState?.inferenceActive == true {
        print("Provider is currently serving requests. Waiting up to \(Int(timeout))s for them to finish before \(action.verb)...")
    }

    // Drain all loaded-label daemons concurrently so the total wait is bounded by
    // `timeout` even when two jobs are loaded.
    let outcomes = await withTaskGroup(of: ProcessLifecycle.GracefulStopOutcome.self) { group in
        for pid in pids {
            group.addTask { await ProcessLifecycle.stopProcessGracefully(pid: pid, timeout: timeout) }
        }
        var results: [ProcessLifecycle.GracefulStopOutcome] = []
        for await outcome in group { results.append(outcome) }
        return results
    }

    let forceKilled = outcomes.contains { if case .forceKilled = $0 { return true } else { return false } }
    if forceKilled {
        print("Warning: provider did not stop within \(Int(timeout))s; force-killing before \(action.verb).")
    }
    // True if at least one live daemon was found and signalled (so the caller
    // knows a graceful drain was attempted).
    return outcomes.contains { $0 != .notRunning }
}
