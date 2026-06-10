import Foundation

/// AutoUpdateController -- orchestrates a single graceful auto-update cycle.
///
/// The ordering is the whole point, and it is deliberately different from a
/// naive "stop, update, start":
///
///   1. **check** for a newer release (cheap; runs even while serving).
///   2. **download + verify + install** the new binary *while still serving*.
///      The running process keeps the old binary in memory, so installing the
///      new one on disk is safe and invisible to in-flight requests. If this
///      step fails we abort and keep serving — a botched update never causes
///      downtime.
///   3. only after a successful install do we **begin draining**: new requests
///      are refused (the caller's gate returns 503 so the coordinator reroutes)
///      while in-flight requests are allowed to finish.
///   4. **wait for the drain** to reach zero (bounded). On timeout we
///      force-cancel the stragglers rather than block the update forever.
///   5. **restart** (hot-swap) into the freshly-installed binary.
///
/// All side effects are injected so the sequencing can be unit-tested without
/// the network, the filesystem, or launchd. The controller itself owns no
/// mutable state; the phase lifecycle (claim/resume/drain) lives behind the
/// injected actor closures so the real `ProviderLoop` keeps a single,
/// atomic source of truth for its update phase.
public struct AutoUpdateController: Sendable {

    /// Result of the download + verify + install step. A dedicated type (rather
    /// than `Result<Void, Error>`) keeps the failure reason a plain string for
    /// logging without dragging an `Error`-conforming type through the seam.
    public enum InstallOutcome: Sendable, Equatable {
        case installed
        case failed(String)
    }

    /// Collaborators the controller drives. The real wiring lives in
    /// `ProviderLoop`; tests substitute fakes that record the call order.
    public struct Dependencies: Sendable {
        /// Atomically claim the update cycle. Returns `false` if a cycle is
        /// already underway (re-entrancy guard), in which case `run()` is a
        /// no-op. On `true`, the provider has entered the "installing" phase
        /// (still serving).
        public var claimStart: @Sendable () async -> Bool
        /// Return to normal serving. Called on every exit that does NOT end in
        /// a restart (up-to-date, check failure, download/install failure,
        /// restart failure) so a later tick can retry.
        public var resumeServing: @Sendable () async -> Void
        /// Check the coordinator for a newer release.
        public var check: @Sendable () async -> UpdateCheckResult
        /// Download, verify, and install the release bundle. `.installed` means
        /// the new binary is on disk; the process is still running the old one.
        public var downloadVerifyInstall: @Sendable (ReleaseInfo) async -> InstallOutcome
        /// Stop accepting new requests (drain mode). In-flight requests continue.
        public var beginDraining: @Sendable () async -> Void
        /// Wait until in-flight work reaches zero or `timeout` elapses.
        /// Returns `true` if fully drained, `false` on timeout.
        public var waitForDrain: @Sendable (Duration) async -> Bool
        /// Cancel any remaining in-flight requests (drain-timeout fallback).
        public var forceCancelInflight: @Sendable () async -> Void
        /// Restart the process into the new binary. In production this does not
        /// return (the process is replaced/relaunched by launchd).
        public var restart: @Sendable () throws -> Void
        /// Emit a human-readable progress line.
        public var log: @Sendable (String) -> Void

        public init(
            claimStart: @escaping @Sendable () async -> Bool,
            resumeServing: @escaping @Sendable () async -> Void,
            check: @escaping @Sendable () async -> UpdateCheckResult,
            downloadVerifyInstall: @escaping @Sendable (ReleaseInfo) async -> InstallOutcome,
            beginDraining: @escaping @Sendable () async -> Void,
            waitForDrain: @escaping @Sendable (Duration) async -> Bool,
            forceCancelInflight: @escaping @Sendable () async -> Void,
            restart: @escaping @Sendable () throws -> Void,
            log: @escaping @Sendable (String) -> Void
        ) {
            self.claimStart = claimStart
            self.resumeServing = resumeServing
            self.check = check
            self.downloadVerifyInstall = downloadVerifyInstall
            self.beginDraining = beginDraining
            self.waitForDrain = waitForDrain
            self.forceCancelInflight = forceCancelInflight
            self.restart = restart
            self.log = log
        }
    }

    /// The terminal result of a `run()` cycle, for logging and tests.
    public enum Outcome: Sendable, Equatable {
        /// A cycle was already in progress; this call did nothing.
        case alreadyRunning
        /// Already on the latest version.
        case upToDate
        /// The version check failed.
        case checkFailed(String)
        /// Download/verify/install failed; the provider kept serving the old version.
        case downloadOrInstallFailed(String)
        /// The new binary was installed and a restart was issued. `drained`
        /// indicates whether in-flight work finished cleanly (`true`) or was
        /// force-cancelled on timeout (`false`).
        case restarted(from: String, to: String, drained: Bool)
        /// Install succeeded but the restart call itself failed.
        case restartFailed(String)
    }

    private let deps: Dependencies
    private let drainTimeout: Duration

    public init(deps: Dependencies, drainTimeout: Duration) {
        self.deps = deps
        self.drainTimeout = drainTimeout
    }

    /// Run one full update cycle. Safe to call repeatedly; concurrent calls are
    /// serialized by `claimStart` (the second one returns `.alreadyRunning`).
    @discardableResult
    public func run() async -> Outcome {
        guard await deps.claimStart() else {
            return .alreadyRunning
        }

        let checkResult = await deps.check()
        switch checkResult {
        case .upToDate:
            await deps.resumeServing()
            return .upToDate

        case .checkFailed(let reason):
            deps.log("auto-update: check failed: \(reason)")
            await deps.resumeServing()
            return .checkFailed(reason)

        case .updateAvailable(let current, let release):
            deps.log("auto-update: v\(current) -> v\(release.version) available; downloading while serving")

            switch await deps.downloadVerifyInstall(release) {
            case .failed(let reason):
                // A failed update must never cost us serving capacity: stay on
                // the current version and let the next tick retry.
                deps.log("auto-update: download/install failed, staying on v\(current): \(reason)")
                await deps.resumeServing()
                return .downloadOrInstallFailed(reason)

            case .installed:
                deps.log("auto-update: v\(release.version) installed; draining in-flight requests before restart")
                await deps.beginDraining()

                let drained = await deps.waitForDrain(drainTimeout)
                if !drained {
                    deps.log("auto-update: drain timed out after \(drainTimeout.components.seconds)s; cancelling remaining requests")
                    await deps.forceCancelInflight()
                }

                deps.log("auto-update: restarting into v\(release.version)")
                do {
                    try deps.restart()
                } catch {
                    // Restart failed but the binary is already installed; resume
                    // serving (on the old in-memory binary) so we aren't wedged.
                    deps.log("auto-update: restart failed: \(error.localizedDescription)")
                    await deps.resumeServing()
                    return .restartFailed("\(error)")
                }
                return .restarted(from: current, to: release.version, drained: drained)
            }
        }
    }
}
