/// WatchdogProbe -- "is the provider loaded / up?" liveness for the watchdog.
///
/// Reports two facts the watchdog policy needs:
///   - **loaded**: launchd has the provider job registered. `false` means the
///     user stopped (`bootout`) or uninstalled it — not a crash.
///   - **running**: the provider process is actually alive.
///
/// Liveness uses two independent signals, OR'd so a transient quirk in one never
/// causes a false restart of a healthy provider:
///
///   1. **launchd (authoritative).** `launchctl print gui/<uid>/<label>` shows a
///      running `pid`/`state = running` whenever the daemon process exists —
///      including while it is still loading a model (cold loads take a couple of
///      minutes) — so a slow-to-serve provider never reads as down. A crashed
///      provider (KeepAlive=false) is loaded but shows `state = not running`.
///   2. **daemon state file (backup).** If launchctl parsing ever misses, a
///      *fresh* `~/.darkbloom/daemon-state.json` whose pid is alive also counts
///      as running. Freshness matters: a crashed daemon leaves a stale file, so
///      requiring not-stale avoids being fooled by a recycled pid.

import Foundation

public enum WatchdogProbe {

    /// Combined loaded/running snapshot of the provider.
    public struct ProviderLiveness: Sendable, Equatable {
        public let loaded: Bool
        public let running: Bool
        public init(loaded: Bool, running: Bool) {
            self.loaded = loaded
            self.running = running
        }
    }

    /// Probe the provider across all supported labels with a single `launchctl
    /// print` per label, falling back to the daemon state file for liveness.
    public static func probeProvider(now: Double = Date().timeIntervalSince1970) -> ProviderLiveness {
        var loaded = false
        var running = false

        for label in LaunchAgent.supportedLabels {
            let result = LaunchctlControl.printOutput(label: label)
            guard result.succeeded else { continue } // not loaded under this label
            loaded = true
            if parseRunning(result.stdout) {
                running = true
                break
            }
        }

        if !running,
           let state = DaemonStateFile.read(),
           !state.isStale(now: now),
           daemonProcessAlive(pid: state.pid) {
            running = true
        }

        return ProviderLiveness(loaded: loaded, running: running)
    }

    /// Parse `launchctl print` output for a live process. Pure, so it can be
    /// unit-tested against captured samples across macOS versions.
    ///
    /// Matches an explicit `state = running` or a non-zero `pid = N`, and is
    /// careful NOT to match `state = not running`.
    static func parseRunning(_ output: String) -> Bool {
        let lower = output.lowercased()
        if lower.range(of: #"state\s*=\s*running"#, options: .regularExpression) != nil {
            return true
        }
        if lower.range(of: #"\bpid\s*=\s*[1-9][0-9]*"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }
}
