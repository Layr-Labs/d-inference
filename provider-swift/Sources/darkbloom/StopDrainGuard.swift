import Foundation
import ProviderCore

/// Pure, testable guard for whether `darkbloom stop` should wait.
///
/// Decouples the stop command's CLI orchestration from the daemon-state
/// freshness/liveness policy so it can be unit-tested without launchctl or a
/// live daemon. No I/O, no side effects.
enum StopDrainGuard {
    /// Whether the daemon's current state indicates in-flight work that the
    /// stop command should wait for.
    ///
    /// Returns `false` when the state is missing, stale, the pid is not alive,
    /// or no inference is active — in all those cases stopping immediately is
    /// safe.
    static func shouldWait(state: DaemonState?, now: Double) -> Bool {
        guard let state else { return false }
        if state.isStale(now: now) { return false }
        if !daemonProcessAlive(pid: state.pid) { return false }
        return state.inferenceActive
    }
}
