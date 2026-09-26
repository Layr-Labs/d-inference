import Foundation
import ProviderAppAttest

/// Classifies why this provider process started from local lifecycle evidence
/// only; falls back to `unknown` rather than guessing.
public enum ProviderStartReason {
    /// Evidence counts only if recorded at most this long before the process
    /// started (a relaunch lands within seconds of its trigger), or at any
    /// point since then (an in-place exec keeps the original start time).
    public static let recencyWindow: TimeInterval = 120

    public struct Evidence: Sendable, Equatable {
        public var processStartedAt: Double
        /// When the classification runs.
        public var now: Double
        public var previousRun: ProviderRunMarker.Record?
        public var currentVersion: String
        public var stallRestartAt: Double?
        public var watchdogRestartAt: Double?
        /// The provider LaunchAgent started this process (XPC_SERVICE_NAME).
        public var launchedByLaunchd: Bool

        public init(processStartedAt: Double, now: Double, previousRun: ProviderRunMarker.Record?, currentVersion: String,
                    stallRestartAt: Double?, watchdogRestartAt: Double?, launchedByLaunchd: Bool) {
            self.processStartedAt = processStartedAt
            self.now = now
            self.previousRun = previousRun
            self.currentVersion = currentVersion
            self.stallRestartAt = stallRestartAt
            self.watchdogRestartAt = watchdogRestartAt
            self.launchedByLaunchd = launchedByLaunchd
        }
    }

    /// First match wins: stall_restart, watchdog, update, manual, launchd.
    public static func classify(_ e: Evidence) -> AppAttestStartReason {
        func recent(_ at: Double?) -> Bool {
            guard let at, at.isFinite else { return false }
            return at >= e.processStartedAt - recencyWindow && at <= e.now + 5
        }
        let exit = e.previousRun?.exitCause
        let exitedRecently = recent(e.previousRun?.exitedAt)
        if recent(e.stallRestartAt) || (exit == .stallRestart && exitedRecently) { return .stallRestart }
        if recent(e.watchdogRestartAt) { return .watchdog }
        if let previous = e.previousRun?.version, previous != e.currentVersion { return .update }
        if exit == .update && exitedRecently { return .update }
        if exit == .lifecycleCommand && exitedRecently { return .manual }
        if !e.launchedByLaunchd { return .manual }
        return .launchd
    }

    /// launchd sets XPC_SERVICE_NAME to the job label for agents it spawns.
    public static func launchedByLaunchd(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let name = environment["XPC_SERVICE_NAME"] else { return false }
        return LaunchAgent.supportedLabels.contains(name)
    }
}
