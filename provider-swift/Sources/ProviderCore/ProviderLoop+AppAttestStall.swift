import Foundation
import ProviderAppAttest

/// A DeviceCheck callback that never arrives keeps App Attest answering `busy`
/// until the process exits. Once stalled, restart gracefully through the same
/// lease, drain and launchd path as a background update, at most once per
/// `AppAttestStallRestartPolicy.minimumInterval`, and never while accepted
/// inference or another lifecycle operation is in progress.
extension ProviderLoop {
    private static let appAttestStallCheckInterval: Duration = .seconds(60)
    private static let appAttestStallDrainTimeout: Duration = .seconds(120)

    /// Started when an exchange ends `busy` or `operation_timeout`, which is
    /// when an unanswered Apple call can be holding admission. One monitor per
    /// process; it ends as soon as Apple's callback releases the gate.
    internal func startAppAttestStallMonitorIfNeeded() {
        guard appAttestStallMonitorTask == nil, !isShuttingDown else { return }
        appAttestStallMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, await self.evaluateAppAttestStallRestart() else { return }
                try? await taskSleep(Self.appAttestStallCheckInterval)
            }
        }
    }

    internal func cancelAppAttestStallMonitor() {
        appAttestStallMonitorTask?.cancel()
        appAttestStallMonitorTask = nil
    }

    /// Returns whether monitoring should continue.
    private func evaluateAppAttestStallRestart() async -> Bool {
        guard let client = appAttestShadowClient, !isShuttingDown, !Task.isCancelled,
              let heldSince = await client.appleOperationHeldSince() else {
            if appAttestStallLastSkip != nil { logger.info("App Attest: stalled Apple operation completed; no restart needed") }
            appAttestStallLastSkip = nil
            publishAppAttestStall(nil)
            appAttestStallMonitorTask = nil
            return false
        }
        let now = Date()
        guard let stalled = AppleOperationStall.reportedSeconds(heldSince: heldSince, now: now) else { return true }
        publishAppAttestStall(stalled)
        let marker = appAttestStallRestartMarker()
        let decision = AppAttestStallRestartPolicy.decide(
            stalledSeconds: stalled, inferenceActive: hasInflightWork || isLoadingAny,
            lifecycleBusy: updatePhase != .idle || servingDrain.refusing || lifecycleDrainTask != nil,
            lastRestartAt: marker.lastRestart(), retryDeferred: appAttestStallRetryDeferred, now: now)
        switch decision {
        case .skip(let reason):
            if reason != appAttestStallLastSkip {
                logger.warning("App Attest: Apple operation stalled for \(stalled)s; automatic restart deferred (\(reason.rawValue))")
            }
            appAttestStallLastSkip = reason
            return true
        case .restart:
            return await restartForStalledAppAttest(stalledSeconds: stalled, marker: marker)
        }
    }

    /// Keeps `darkbloom doctor` current between coordinator exchanges.
    private func publishAppAttestStall(_ seconds: Int?) {
        guard var status = appAttestLocalStatus, status.operationStalledSeconds != seconds else { return }
        status.operationStalledSeconds = seconds
        appAttestLocalStatus = status
        writeDaemonState()
    }

    private func restartForStalledAppAttest(stalledSeconds: Int, marker: AppAttestStallRestartMarker) async -> Bool {
        let updater = SelfUpdater(coordinatorBaseURL: loopConfig.coordinatorURL)
        // The cross-process update lease excludes CLI stop/restart and updates.
        guard claimUpdateStart(updater: updater) else {
            appAttestStallLastSkip = .lifecycleBusy
            return true
        }
        logger.warning("App Attest: Apple operation stalled for \(stalledSeconds)s; draining for a graceful provider restart to release DeviceCheck admission (at most once per \(Int(AppAttestStallRestartPolicy.minimumInterval / 3600))h)")
        beginUpdateDraining()
        guard await waitForSafeDisconnect(timeout: Self.appAttestStallDrainTimeout, reason: "App Attest stall restart"),
              !Task.isCancelled else {
            logger.warning("App Attest: stall restart deferred \(Int(AppAttestStallRestartPolicy.drainRetryDelay / 60)) min; accepted work or coordinator acknowledgement is still pending")
            await abandonAppAttestStallRestart(after: .drainNotAcknowledged)
            return true
        }
        // Apple's callback may have arrived, or a CLI stop, OS termination or
        // scheduled shutdown may have taken over the drain, while we awaited.
        // Nothing below suspends, so this is the last point to re-check both.
        let heldSince = await appAttestShadowClient?.appleOperationHeldSince()
        let ownsDrain = appAttestStallRestartOwnsDrain && !Task.isCancelled
        switch AppAttestStallRestartPolicy.afterDrain(updateOwnsDrain: ownsDrain, heldSince: heldSince, now: Date()) {
        case .lifecycleTookOver:
            logger.info("App Attest: stall restart abandoned; a lifecycle drain or shutdown took over")
            appAttestStallMonitorTask = nil
            // Releases the update lease; lifecycle-owned admission stays closed.
            await resumeServingAfterUpdate()
            return false
        case .recovered:
            // App Attest recovered on its own: resume serving without spending
            // the six-hour marker or reloading models.
            logger.info("App Attest: stalled Apple operation completed during drain; resuming without a restart")
            appAttestStallLastSkip = nil
            appAttestStallMonitorTask = nil
            publishAppAttestStall(nil)
            await resumeServingAfterUpdate()
            return false
        case .restart:
            break
        }
        do {
            // Record only once the restart is due, but before issuing it: a
            // restart that fails or loops cannot exceed the limit.
            try marker.record(Date())
        } catch {
            logger.warning("App Attest: cannot persist the stall restart marker; not restarting for \(Int(AppAttestStallRestartPolicy.minimumInterval / 3600))h: \(error)")
            await abandonAppAttestStallRestart(after: .markerNotPersisted)
            return true
        }
        if case .failed(let reason) = prepareInstalledCandidateRestart(updater: updater) {
            logger.warning("App Attest: stall restart not issued: \(reason)")
            await resumeServingAfterUpdate()
            return true
        }
        do {
            try ProcessLifecycle.restartAfterUpdate()
        } catch {
            logger.warning("App Attest: stall restart failed: \(error)")
            try? updater.cancelPendingCandidateAttempt(operation: "app-attest-stall-restart-failure")
            await resumeServingAfterUpdate()
            return true
        }
    }

    /// An attempt that closed admission but will not restart: reopen serving
    /// and keep the monitor from draining again on its next tick. Failures
    /// after the marker is written are already limited by the marker.
    internal func abandonAppAttestStallRestart(after failure: AppAttestStallRestartPolicy.FailedAttempt) async {
        appAttestStallRetryAt = ContinuousClock.now.advanced(
            by: .seconds(AppAttestStallRestartPolicy.retryDelay(after: failure)))
        await resumeServingAfterUpdate()
    }

    internal var appAttestStallRetryDeferred: Bool {
        appAttestStallRetryAt.map { ContinuousClock.now < $0 } ?? false
    }

    /// Whether the drain begun for a stall restart is still update-owned.
    /// `ProviderDrain.begin(.lifecycle)` takes over without cancelling the
    /// stall monitor, so the restart path must check this itself.
    internal var appAttestStallRestartOwnsDrain: Bool {
        !isShuttingDown && lifecycleDrainTask == nil && servingDrain.owner == .update && updatePhase == .draining
    }

    private func appAttestStallRestartMarker() -> AppAttestStallRestartMarker {
        AppAttestStallRestartMarker(
            directory: (daemonStateFileOverride ?? DaemonStateFile.path()).deletingLastPathComponent())
    }
}
