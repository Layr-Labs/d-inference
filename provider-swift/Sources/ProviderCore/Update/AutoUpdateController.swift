import Foundation

/// AutoUpdateController -- orchestrates a single graceful auto-update cycle.
///
/// The ordering is the whole point, and it is deliberately different from a
/// naive "stop, update, start":
///
///   1. **check** for a newer release (cheap; runs even while serving).
///   2. **download + verify + stage** the new bundle *while still serving*.
///      Staging extracts and verifies into a side directory and never touches
///      the live layout, so a botched download/verify is invisible to
///      in-flight and future requests — the running process keeps serving the
///      old binary with zero downtime.
///   3. only after a successful stage do we **begin draining**: new requests
///      are refused (the caller's gate returns 503 so the coordinator
///      reroutes) while in-flight requests are allowed to finish.
///   4. **wait for the drain** to reach zero (bounded). On timeout we
///      force-cancel the stragglers rather than block the update forever.
///   5. **commit** the staged bundle into the live layout. This is the only
///      step that mutates the running install, and it happens strictly after
///      admission is closed and in-flight work has drained, so no request can
///      ever observe a half-replaced bundle (executable, mlx.metallib, ...).
///   6. **restart** (hot-swap) into the freshly-installed binary.
///
/// All side effects are injected so the sequencing can be unit-tested without
/// the network, the filesystem, or launchd. The controller itself owns no
/// mutable state; the phase lifecycle (claim/resume/drain) and the staged
/// bundle live behind the injected actor closures so the real `ProviderLoop`
/// keeps a single, atomic source of truth.
public struct AutoUpdateController: Sendable {

    /// Result of one injected update step (stage or commit). A dedicated type
    /// (rather than `Result<Void, Error>`) keeps the failure reason a plain
    /// string for logging without dragging an `Error`-conforming type through
    /// the seam.
    public enum StepOutcome: Sendable, Equatable {
        case completed
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
        /// a restart (up-to-date, check failure, stage failure, commit
        /// failure, restart failure) so a later tick can retry.
        public var resumeServing: @Sendable () async -> Void
        /// Check the coordinator for a newer release.
        public var check: @Sendable () async -> UpdateCheckResult
        /// Download, verify, and stage the release bundle WITHOUT touching the
        /// live layout. `.completed` means a verified bundle is staged on
        /// disk; the process keeps serving the old binary.
        public var downloadVerifyStage: @Sendable (ReleaseInfo) async -> StepOutcome
        /// Stop accepting new requests (drain mode). In-flight requests continue.
        public var beginDraining: @Sendable () async -> Void
        /// Wait until in-flight work reaches zero or `timeout` elapses.
        /// Returns `true` if fully drained, `false` on timeout.
        public var waitForDrain: @Sendable (Duration) async -> Bool
        /// Cancel any remaining in-flight requests (drain-timeout fallback).
        public var forceCancelInflight: @Sendable () async -> Void
        /// Swap the staged bundle into the live layout. Runs only after the
        /// drain (admission closed, in-flight work finished or cancelled).
        public var commitInstall: @Sendable () async -> StepOutcome
        /// Restart the process into the new binary. In production this does not
        /// return (the process is replaced/relaunched by launchd).
        public var restart: @Sendable () throws -> Void
        /// Emit a human-readable progress line.
        public var log: @Sendable (String) -> Void

        public init(
            claimStart: @escaping @Sendable () async -> Bool,
            resumeServing: @escaping @Sendable () async -> Void,
            check: @escaping @Sendable () async -> UpdateCheckResult,
            downloadVerifyStage: @escaping @Sendable (ReleaseInfo) async -> StepOutcome,
            beginDraining: @escaping @Sendable () async -> Void,
            waitForDrain: @escaping @Sendable (Duration) async -> Bool,
            forceCancelInflight: @escaping @Sendable () async -> Void,
            commitInstall: @escaping @Sendable () async -> StepOutcome,
            restart: @escaping @Sendable () throws -> Void,
            log: @escaping @Sendable (String) -> Void
        ) {
            self.claimStart = claimStart
            self.resumeServing = resumeServing
            self.check = check
            self.downloadVerifyStage = downloadVerifyStage
            self.beginDraining = beginDraining
            self.waitForDrain = waitForDrain
            self.forceCancelInflight = forceCancelInflight
            self.commitInstall = commitInstall
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
        /// Download/verify/stage failed; the provider kept serving the old
        /// version without ever draining.
        case stageFailed(String)
        /// The staged bundle could not be swapped into the live layout; the
        /// provider resumed serving the old version after the drain.
        case commitFailed(String)
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
            deps.log("auto-update: v\(current) -> v\(release.version) available; staging download while serving")

            switch await deps.downloadVerifyStage(release) {
            case .failed(let reason):
                // A failed update must never cost us serving capacity: stay on
                // the current version and let the next tick retry.
                deps.log("auto-update: download/stage failed, staying on v\(current): \(reason)")
                await deps.resumeServing()
                return .stageFailed(reason)

            case .completed:
                deps.log("auto-update: v\(release.version) staged; draining in-flight requests before install + restart")
                await deps.beginDraining()

                let drained = await deps.waitForDrain(drainTimeout)
                if !drained {
                    deps.log("auto-update: drain timed out after \(drainTimeout.components.seconds)s; cancelling remaining requests")
                    await deps.forceCancelInflight()
                }

                switch await deps.commitInstall() {
                case .failed(let reason):
                    // The live layout was restored (or never touched); resume
                    // serving on the current version and retry next tick.
                    deps.log("auto-update: installing staged v\(release.version) failed, staying on v\(current): \(reason)")
                    await deps.resumeServing()
                    return .commitFailed(reason)

                case .completed:
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
}
