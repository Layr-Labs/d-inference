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
           DaemonStateRuntimeTruth.belongsToLiveProcess(state) {
            running = true
        }
        return ProviderLiveness(loaded: loaded, running: running)
    }

    /// A live launchd process becomes inactive only when a daemon-state record
    /// attributable to that still-live PID has gone stale. No state (normal
    /// during initial model preload) or a state record from a dead prior PID
    /// does not override launchd liveness.
    public static func providerActive(
        processRunning: Bool,
        daemonState: DaemonState?,
        now: Double,
        readIdentity: (Int32) -> ProcessIdentity? = ProcessIdentity.read
    ) -> Bool {
        guard processRunning else { return false }
        guard let daemonState,
              DaemonStateRuntimeTruth.belongsToLiveProcess(
                daemonState,
                readIdentity: readIdentity
              )
        else {
            return true
        }
        return !daemonState.isStale(now: now)
    }

    /// The provider's process identity for stale-lock-owner attribution.
    ///
    /// A daemon-state PID is trusted ONLY when the currently-live process at
    /// that PID has the SAME kernel start time the daemon recorded. If the PID
    /// was reused (the recorded process died and the kernel handed its PID to
    /// an unrelated process — e.g. a manual `darkbloom update` that now holds
    /// the update lock), the start times differ and we fall back to the launchd
    /// snapshot's process. This prevents the watchdog from force-killing a live,
    /// unrelated process that merely inherited the provider's old PID.
    public static func providerIdentity(
        daemonState: DaemonState?,
        launchSnapshotProcess: ProcessIdentity?,
        readIdentity: (Int32) -> ProcessIdentity? = ProcessIdentity.read
    ) -> ProcessIdentity? {
        if let recorded = daemonState?.processIdentity,
           let live = readIdentity(recorded.pid),
           live == recorded {
            return live
        }
        return launchSnapshotProcess
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
