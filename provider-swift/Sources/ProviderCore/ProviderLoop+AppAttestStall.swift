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
            lastRestartAt: marker.lastRestart(), now: now)
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
            logger.warning("App Attest: stall restart deferred; accepted work or coordinator acknowledgement is still pending")
            await resumeServingAfterUpdate()
            return true
        }
        // Apple's callback may have arrived while we drained. If the gate is
        // idle again, App Attest recovered on its own: resume serving without
        // spending the six-hour marker or reloading models.
        let heldSince = await appAttestShadowClient?.appleOperationHeldSince()
        guard AppAttestStallRestartPolicy.stillStalled(heldSince: heldSince, now: Date()) else {
            logger.info("App Attest: stalled Apple operation completed during drain; resuming without a restart")
            appAttestStallLastSkip = nil
            publishAppAttestStall(nil)
            await resumeServingAfterUpdate()
            return false
        }
        do {
            // Record only once the restart is due, but before issuing it: a
            // restart that fails or loops cannot exceed the limit.
            try marker.record(Date())
        } catch {
            logger.warning("App Attest: cannot persist the stall restart marker; not restarting: \(error)")
            await resumeServingAfterUpdate()
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

    private func appAttestStallRestartMarker() -> AppAttestStallRestartMarker {
        AppAttestStallRestartMarker(
            directory: (daemonStateFileOverride ?? DaemonStateFile.path()).deletingLastPathComponent())
    }
}
