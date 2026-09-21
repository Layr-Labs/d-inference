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
        /// Rollover jitter: awaited AFTER the bundle is verified + staged and
        /// BEFORE the drain begins, so a fleet that discovers a release on
        /// aligned update ticks does not drain + restart in unison (the
        /// v0.6.30 cold-restart storm). The provider keeps serving normally
        /// while it waits, and no security-critical check is deferred (verify
        /// already ran). Defaults to a no-op; production wires a uniformly
        /// random sleep of up to `update_jitter_seconds`.
        public var waitBeforeInstall: @Sendable () async -> Void
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
        /// Arm the already-installed candidate before retrying a restart after
        /// a prior restart command or process died.
        public var prepareInstalledRestart: @Sendable () async -> StepOutcome
        /// Restart the process into the new binary. In production this does not
        /// return (the process is replaced/relaunched by launchd).
        public var restart: @Sendable () throws -> Void
        /// Undo the pending-attempt marker if `restart` throws before launch.
        public var restartDidFail: @Sendable () async -> Void
        /// Emit a human-readable progress line.
        public var log: @Sendable (String) -> Void

        public init(
            claimStart: @escaping @Sendable () async -> Bool,
            resumeServing: @escaping @Sendable () async -> Void,
            check: @escaping @Sendable () async -> UpdateCheckResult,
            downloadVerifyStage: @escaping @Sendable (ReleaseInfo) async -> StepOutcome,
            waitBeforeInstall: @escaping @Sendable () async -> Void = {},
            beginDraining: @escaping @Sendable () async -> Void,
            waitForDrain: @escaping @Sendable (Duration) async -> Bool,
            forceCancelInflight: @escaping @Sendable () async -> Void,
            commitInstall: @escaping @Sendable () async -> StepOutcome,
            prepareInstalledRestart: @escaping @Sendable () async -> StepOutcome = { .completed },
            restart: @escaping @Sendable () throws -> Void,
            restartDidFail: @escaping @Sendable () async -> Void = {},
            log: @escaping @Sendable (String) -> Void
        ) {
            self.claimStart = claimStart
            self.resumeServing = resumeServing
            self.check = check
            self.downloadVerifyStage = downloadVerifyStage
            self.waitBeforeInstall = waitBeforeInstall
            self.beginDraining = beginDraining
            self.waitForDrain = waitForDrain
            self.forceCancelInflight = forceCancelInflight
            self.commitInstall = commitInstall
            self.prepareInstalledRestart = prepareInstalledRestart
            self.restart = restart
            self.restartDidFail = restartDidFail
            self.log = log
        }
    }

    /// The terminal result of a `run()` cycle, for logging and tests.
    public enum Outcome: Sendable, Equatable {
        /// A cycle was already in progress; this call did nothing.
        case alreadyRunning
        /// The cycle was cancelled (provider shutdown / monitor teardown)
        /// during the pre-install rollover-jitter wait. Nothing was drained,
        /// committed, or restarted; the staged bundle is discarded by
        /// `resumeServing` and a later tick can retry.
        case cancelled
        /// Already on the latest version.
        case upToDate
        /// Latest release is the exact locally quarantined failed version.
        case quarantined(String)
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

        case .quarantined(let version, let reason):
            deps.log("auto-update: v\(version) is quarantined locally: \(reason)")
            await deps.resumeServing()
            return .quarantined(version)

        case .restartRequired(let current, let installed):
            deps.log(
                "auto-update: v\(installed) is already installed but not running; draining before restart")
            await deps.beginDraining()
            let drained = await deps.waitForDrain(drainTimeout)
            if !drained {
                await deps.forceCancelInflight()
            }
            return await restartInstalled(from: current, to: installed, drained: drained)

        case .checkFailed(let reason):
            deps.log("auto-update: check failed: \(reason)")
            await deps.resumeServing()
            return .checkFailed(reason)

        case .updateAvailable(let current, let release):
            return await installUpdate(from: current, release: release)
        }
    }

    /// The staged update owns jitter, drain and commit. A failed pre-install
    /// phase returns before admission closes; restart handling is shared with
    /// candidates that a previous cycle already installed.
    private func installUpdate(from current: String, release: ReleaseInfo) async -> Outcome {
        deps.log("auto-update: v\(current) -> v\(release.version) available; staging download while serving")
        if case .failed(let reason) = await deps.downloadVerifyStage(release) {
            deps.log("auto-update: download/stage failed, staying on v\(current): \(reason)")
            await deps.resumeServing()
            return .stageFailed(reason)
        }
        await deps.waitBeforeInstall()
        // An interrupted jitter wait is not permission to drain or install.
        if Task.isCancelled {
            deps.log("auto-update: cycle cancelled during the pre-install wait; aborting before drain")
            await deps.resumeServing()
            return .cancelled
        }
        deps.log("auto-update: v\(release.version) staged; draining in-flight requests before install + restart")
        await deps.beginDraining()
        let drained = await deps.waitForDrain(drainTimeout)
        if !drained {
            deps.log("auto-update: drain timed out after \(drainTimeout.components.seconds)s; cancelling remaining requests")
            await deps.forceCancelInflight()
        }
        if case .failed(let reason) = await deps.commitInstall() {
            deps.log("auto-update: installing staged v\(release.version) failed, staying on v\(current): \(reason)")
            await deps.resumeServing()
            return .commitFailed(reason)
        }
        deps.log("auto-update: restarting into v\(release.version)")
        return await restartInstalled(from: current, to: release.version, drained: drained, logFailure: true)
    }

    /// Preparing or launching an installed candidate can fail on either path.
    /// Retire the attempt before resuming only when launch itself throws.
    private func restartInstalled(
        from current: String, to installed: String, drained: Bool, logFailure: Bool = false
    ) async -> Outcome {
        if case .failed(let reason) = await deps.prepareInstalledRestart() {
            await deps.resumeServing()
            return .restartFailed(reason)
        }
        do {
            try deps.restart()
            return .restarted(from: current, to: installed, drained: drained)
        } catch {
            if logFailure { deps.log("auto-update: restart failed: \(error.localizedDescription)") }
            await deps.restartDidFail()
            await deps.resumeServing()
            return .restartFailed("\(error)")
        }
    }
}
