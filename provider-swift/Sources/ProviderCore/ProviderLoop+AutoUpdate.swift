/// ProviderLoop -- background self-update.
///
/// Periodically checks for a newer signed bundle, drains in-flight work, stages
/// and commits the update, and manages the serving/draining phase transitions.

import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
import MLXVLM
#if canImport(os)
import os
#endif

extension ProviderLoop {
    // MARK: - Background Auto-Update

    /// Initial delay before the first background update check (5 minutes).
    /// Avoids slowing down startup; lets the provider stabilize first.
    private static let autoUpdateInitialDelay: Duration = .seconds(300)

    /// Interval between subsequent update checks (30 minutes).
    private static let autoUpdateInterval: Duration = .seconds(1800)

    /// Start the background auto-update monitor. Checks the coordinator for a
    /// newer release every 30 minutes (after an initial 5-minute delay). On a
    /// new release it downloads + verifies + installs the binary *while still
    /// serving*, then stops accepting new requests, drains in-flight work to
    /// zero, and finally hot-swaps (restart). See `AutoUpdateController`.
    ///
    /// The monitor is disabled when:
    ///   - `config.provider.autoUpdate` is false
    ///   - `DARKBLOOM_NO_UPDATE_CHECK` env var is set
    ///
    /// Unlike the old behaviour, a busy provider is NOT skipped: the check and
    /// download run concurrently with serving, and requests are only refused
    /// once the new binary is safely installed.
    ///
    /// Failures are logged at warning level and never crash the provider.
    internal func startAutoUpdateMonitor() {
        autoUpdateTask?.cancel()

        guard loopConfig.config.provider.autoUpdate else {
            logger.info("Background auto-update disabled (auto_update=false)")
            return
        }
        guard ProcessInfo.processInfo.environment["DARKBLOOM_NO_UPDATE_CHECK"] == nil else {
            logger.info("Background auto-update disabled (DARKBLOOM_NO_UPDATE_CHECK set)")
            return
        }

        let coordinatorURL = loopConfig.coordinatorURL
        let me = self
        autoUpdateTask = Task.detached {
            // Wait 5 minutes before first check.
            try? await taskSleep( Self.autoUpdateInitialDelay)

            while !Task.isCancelled {
                await me.performAutoUpdateCheck(coordinatorURL: coordinatorURL)
                // Sleep 30 minutes before next check.
                try? await taskSleep( Self.autoUpdateInterval)
            }
        }
        logger.info("Background auto-update monitor started (initial delay: 5m, interval: 30m)")
    }

    /// Perform a single background update cycle via `AutoUpdateController`.
    /// The controller sequences: check → download/stage (while serving) →
    /// drain → commit → restart. All side effects below are actor-isolated so
    /// the phase transitions, staged-bundle handoff, and drain bookkeeping
    /// stay race-free.
    private func performAutoUpdateCheck(coordinatorURL: String) async {
        // Bounded network (30 s request / 600 s resource): the cross-process
        // update lease is taken BEFORE the check, and `.shared`'s 7-day
        // resource timeout would let a stalled download hold it until the
        // next restart.
        let updater = SelfUpdater.forDaemon(coordinatorBaseURL: coordinatorURL)
        let me = self
        let logger = self.logger
        let jitterMaxSeconds = loopConfig.config.provider.updateJitterSeconds

        let deps = AutoUpdateController.Dependencies(
            claimStart: { await me.claimUpdateStart(updater: updater) },
            resumeServing: { await me.resumeServingAfterUpdate() },
            check: {
                guard let session = await me.activeUpdateSession() else {
                    return .checkFailed(reason: "cross-process update lease was lost")
                }
                return await updater.checkForUpdate(session: session)
            },
            downloadVerifyStage: { release in
                await me.stageUpdateBundle(release: release, updater: updater)
            },
            // Rollover jitter: random 0..update_jitter_seconds sleep between
            // stage and drain so a fleet never restarts (and goes cold) in
            // unison. Background auto-update only — the manual `darkbloom
            // update` command and the startup update check bypass this
            // controller entirely and stay immediate.
            waitBeforeInstall: {
                let delay = UpdateJitter.delay(maxSeconds: jitterMaxSeconds)
                guard delay > .zero else { return }
                let secs = Double(delay.components.seconds)
                    + Double(delay.components.attoseconds) / 1e18
                logger.info(
                    "Auto-update: bundle staged; waiting \(String(format: "%.0f", secs))s rollover jitter before draining (update_jitter_seconds=\(jitterMaxSeconds))")
                try? await taskSleep( delay)
            },
            beginDraining: { await me.beginUpdateDraining() },
            waitForDrain: { timeout in await me.waitForInflightDrain(timeout: timeout) },
            // Drain-timeout fallback. Cancels coordinator-routed work; any
            // residual LOCAL stream is intentionally left for the immediately
            // following restart to tear down (local reservations are released by
            // the engine, which we no longer wait on past the timeout).
            forceCancelInflight: { await me.cancelAllInflight() },
            commitInstall: { await me.commitStagedUpdateBundle(updater: updater) },
            prepareInstalledRestart: {
                await me.prepareInstalledCandidateRestart(updater: updater)
            },
            restart: {
                try await me.closeLinkThenRestart {
                    try ProcessLifecycle.restartAfterUpdate()
                }
            },
            restartDidFail: {
                try? updater.cancelPendingCandidateAttempt(
                    operation: "background-restart-failure")
            },
            log: { logger.info("\($0)") }
        )

        let controller = AutoUpdateController(deps: deps, drainTimeout: Self.gracefulDrainTimeout)
        let outcome = await controller.run()
        switch outcome {
        case .alreadyRunning:
            logger.info("Auto-update: cycle already in progress; skipping this tick")
        case .cancelled:
            logger.info("Auto-update: cycle cancelled during the pre-install wait; nothing installed")
        case .upToDate:
            logger.info("Auto-update: already running latest version")
        case .quarantined(let version):
            logger.warning("Auto-update: v\(version) is quarantined after failed starts")
        case .checkFailed(let reason):
            logger.warning("Auto-update: check failed: \(reason)")
        case .stageFailed(let reason):
            logger.warning("Auto-update: download/stage failed: \(reason)")
        case .commitFailed(let reason):
            logger.warning("Auto-update: staged install failed: \(reason)")
        case .restarted(let from, let to, let drained):
            logger.info("Auto-update: restarting v\(from) -> v\(to) (drained=\(drained))")
        case .restartFailed(let reason):
            logger.warning("Auto-update: restart failed: \(reason)")
        }
    }

    // MARK: - Auto-Update Phase Transitions

    /// Atomically claim the update cycle. Returns `false` if a cycle is already
    /// underway (re-entrancy guard for overlapping monitor ticks). On `true`,
    /// enter the `.installing` phase — still serving while the new bundle
    /// downloads and stages.
    private func claimUpdateStart(updater: SelfUpdater) -> Bool {
        guard updatePhase == .idle, !isShuttingDown else { return false }
        do {
            let session = try updater.beginUpdateSession(
                operation: "background-auto-update",
                timeout: 0
            )
            try session.recover()
            updateSession = session
        } catch {
            logger.info("Auto-update: cross-process lease unavailable: \(error)")
            return false
        }
        updatePhase = .installing
        return true
    }

    private func activeUpdateSession() -> SelfUpdater.UpdateSession? {
        updateSession
    }

    /// Return to normal serving after an update cycle that did not restart
    /// (up-to-date, check/stage/commit failure, or restart failure): reopen
    /// admission, drop any staged-but-uncommitted bundle, and replay the
    /// desired-models state that was deferred during the drain so the
    /// provider converges back onto the coordinator's current desired set.
    internal func resumeServingAfterUpdate() async {
        updatePhase = .idle
        // Quote path mirror (routing v2): quotes may admit again — unless
        // the shutdown drain has begun meanwhile (a cycle refused at commit
        // or restart lands here): the admission gate keeps answering 503 for
        // the rest of that drain, so quotes must keep refusing too.
        state.refusingNewWork = isShuttingDown
        // Re-advertise admission: the drain folded every slot to
        // `reloading`; a full rebuild (the bridges are healthy on this
        // path) restores the live states and the materiality check fires
        // the event heartbeat that lets the coordinator route here again.
        if !isShuttingDown {
            await updateAggregateCapacity()
        }

        if let staged = stagedUpdateBundle {
            stagedUpdateBundle = nil
            staged.discard()
        }
        updateSession?.release()
        updateSession = nil

        if let entries = deferredDesiredModels {
            deferredDesiredModels = nil
            if let send = outboundSend {
                logger.info("Replaying desired_models deferred during update drain (\(entries.count) entr(ies))")
                await reconcileDesiredModels(entries, send: send)
            }
        }
    }

    /// Enter the `.draining` phase: new requests are refused (503 reroute /
    /// local queue-full) while in-flight work finishes ahead of the commit +
    /// hot-swap.
    internal func beginUpdateDraining() {
        updatePhase = .draining
        // Quote path mirror (routing v2): while draining, capacity quotes
        // refuse with `slot_state` exactly like the live admission gate.
        state.refusingNewWork = true
        // Heartbeat mirror: stop being a routing target within a heartbeat.
        publishDrainingCapacity()
    }

    /// Download, verify, and stage the release bundle while still serving.
    /// Nothing under the live layout is touched; the staged bundle waits for
    /// the post-drain commit.
    ///
    /// The stage itself (tar xzf of a ~170 MB bundle, per-file SHA-256,
    /// `codesign --verify --deep`, and the runtime-smoke child that brings up
    /// Metal — each bounded at 120 s) is synchronous and runs OFF the loop
    /// actor: this method is actor-isolated, and `run()`'s event consumer is
    /// too, so running it inline queued every inference_request, cancel,
    /// desired_models and capacity tick for the 10-40 s the stage takes —
    /// "while still serving" in name only. Only the phase transitions and the
    /// staged-bundle handoff stay on the actor.
    private func stageUpdateBundle(
        release: ReleaseInfo,
        updater: SelfUpdater
    ) async -> AutoUpdateController.StepOutcome {
        switch await updater.downloadAndVerify(release: release) {
        case .failure(let error):
            return .failed("\(error)")
        case .success(let tempFile):
            defer { try? FileManager.default.removeItem(at: tempFile) }
            guard let session = updateSession else {
                return .failed("cross-process update lease was lost before staging")
            }
            let outcome = await Self.runUpdateWorkOffActor {
                updater.stageBundle(from: tempFile, release: release, session: session)
            }
            switch outcome {
            case .success(let staged):
                stagedUpdateBundle = staged
                return .completed
            case .failure(let error):
                return .failed("\(error)")
            }
        }
    }

    /// Swap the staged bundle into the live layout. Runs strictly after the
    /// drain: admission is closed and in-flight work has finished (or been
    /// force-cancelled), so no request can observe the swap window. The
    /// tree-hash + codesign re-verification runs off the actor like the
    /// stage (a local endpoint may still be serving).
    internal func commitStagedUpdateBundle(updater: SelfUpdater) async -> AutoUpdateController.StepOutcome {
        // A cycle that claimed before the shutdown drain began must not
        // swap the live layout under a process launchd is waiting on (the
        // restart that would follow is an execv of this draining PID under
        // `stop`, or a `kickstart -k` whose SIGTERM is the trap's forced
        // exit). `resumeServing` discards the staged bundle; the next
        // daemon retries the update at its own first check.
        guard !isShuttingDown else {
            return .failed("provider is shutting down; leaving the live layout untouched")
        }
        guard let staged = stagedUpdateBundle else {
            return .failed("no staged update bundle to install")
        }
        guard let session = updateSession else {
            return .failed("cross-process update lease was lost before commit")
        }
        stagedUpdateBundle = nil
        let result = await Self.runUpdateWorkOffActor {
            updater.commitStagedBundle(staged, session: session)
        }
        switch result {
        case .success:
            return .completed
        case .failure(let error):
            return .failed("\(error)")
        }
    }

    /// Run a synchronous, blocking update step on a detached utility task
    /// and hand the result back to the caller's isolation. The precedent is
    /// `ProviderLoop+Prefetch`'s detached download work.
    nonisolated internal static func runUpdateWorkOffActor<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await Task.detached(priority: .utility) { work() }.value
    }

    /// The restart step, in the order the coordinator needs: close the link
    /// with a goingAway frame FIRST (awaited, bounded), THEN hand the process
    /// to launchd/execv. `restartAfterUpdate` is `kickstart -k` + exit — the
    /// socket used to die with the process, which the coordinator classified
    /// as a `read_error` disconnect (and, with anything in flight, as OOM
    /// suspected). The drain has already run, so nothing is in flight; the
    /// close is not a shutdown request, so if the restart command throws the
    /// reconnect loop re-registers and `resumeServing` keeps the old binary
    /// serving.
    internal func closeLinkThenRestart(
        restartProcess: @Sendable () async throws -> Void
    ) async throws {
        // See `commitStagedUpdateBundle`: never restart a draining process.
        guard !isShuttingDown else { throw ProviderLoopError.shuttingDown }
        await coordinatorClient?.closeForRestart()
        try await restartProcess()
    }

    internal func prepareInstalledCandidateRestart(
        updater: SelfUpdater
    ) -> AutoUpdateController.StepOutcome {
        guard !isShuttingDown else {
            return .failed("provider is shutting down; the candidate restart was not armed")
        }
        guard let session = updateSession else {
            return .failed("cross-process update lease was lost before candidate restart")
        }
        do {
            try updater.prepareCandidateLaunch(
                session: session,
                baseline: LaunchAgent.launchSnapshot()
            )
            session.release()
            updateSession = nil
            return .completed
        } catch {
            return .failed("\(error)")
        }
    }

}
