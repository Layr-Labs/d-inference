/// "Is the provider loaded / up?" for the watchdog.
///
/// `loaded` = launchd has the job registered (false ⇒ stopped/uninstalled).
/// `running` = the process is alive, from `launchctl print` (`state = running`
/// or a live `pid`), with a *fresh* daemon-state file as a fallback. The
/// fallback can only ADD liveness, never remove it, so it can't cause a false
/// restart. launchd reports a live pid even during a slow cold model load, so a
/// busy provider never reads as down.

import Foundation

public enum WatchdogProbe {

    public struct ProviderLiveness: Sendable, Equatable {
        public let loaded: Bool
        public let running: Bool
        public init(loaded: Bool, running: Bool) {
            self.loaded = loaded
            self.running = running
        }
    }

    public static func probeProvider(now: Double = Date().timeIntervalSince1970) -> ProviderLiveness {
        var loaded = false
        var running = false
        for label in LaunchAgent.supportedLabels {
            let result = LaunchctlControl.printOutput(label: label)
            guard result.succeeded else { continue }
            loaded = true
            if parseRunning(result.stdout) { running = true; break }
        }
        if !running,
           let state = DaemonStateFile.read(),
           !state.isStale(now: now),
           daemonProcessAlive(pid: state.pid) {
            running = true
        }
        return ProviderLiveness(loaded: loaded, running: running)
    }

    /// Parse `launchctl print` for a live process: `state = running` or a
    /// non-zero `pid` (and not `state = not running`). Pure, for testing.
    static func parseRunning(_ output: String) -> Bool {
        let lower = output.lowercased()
        if lower.range(of: #"state\s*=\s*running"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"\bpid\s*=\s*[1-9][0-9]*"#, options: .regularExpression) != nil { return true }
        return false
    }
}
