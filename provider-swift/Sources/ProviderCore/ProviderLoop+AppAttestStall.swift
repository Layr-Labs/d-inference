import Foundation
import ProviderAppAttest

/// A DeviceCheck callback that never arrives keeps App Attest answering `busy`
/// until the process exits. Once stalled, restart gracefully through the same
/// lease, drain and launchd path as a background update, at most once per
/// `AppAttestStallRestartPolicy.minimumInterval`, and never while accepted
/// inference or another lifecycle operation is in progress.
///
/// The same monitor, rate limit and restart path cover App Attest that stops
/// being supported (`isSupported == false`, most often right after a
/// self-update) on a Mac whose App Attest the coordinator verified before.
/// That restart goes through launchd only, never an in-place exec.
extension ProviderLoop {
    private static let appAttestStallCheckInterval: Duration = .seconds(60)
    private static let appAttestStallDrainTimeout: Duration = .seconds(120)

    /// Started when an exchange ends `busy` or `operation_timeout`, which is
    /// when an unanswered Apple call can be holding admission. One monitor per
    /// process; it ends as soon as Apple's callback releases the gate.
    internal func startAppAttestStallMonitorIfNeeded() {
        // A cluster member never relaunches its binary unattended.
        guard serveUsesHostServices, !isClusterMember, !usesAppAttestWorker,
              appAttestStallMonitorTask == nil, !isShuttingDown else { return }
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

    /// Called with each `ready` this process answers. Starts the monitor when
    /// `isSupported` is false on a Mac that may restart for it.
    internal func noteAppAttestAvailability(_ status: AppAttestLocalStatus?, now: Date = Date()) {
        // Root-cause evidence for every unsupported answer, whether or not a
        // restart may follow.
        if status?.availabilityReason == .isSupportedFalse { appAttestEvidenceLog("is_supported_false") }
        guard serveUsesHostServices, !isClusterMember, !usesAppAttestWorker, status?.availabilityReason == .isSupportedFalse,
              appAttestUnsupportedRestartEligible(status, now: now) else {
            appAttestUnsupportedSince = nil
            return
        }
        if appAttestUnsupportedSince == nil {
            appAttestUnsupportedSince = now
            logger.warning("App Attest: isSupported is false on a Mac the coordinator verified before; restarting through launchd if it stays false for \(Int(AppAttestStallRestartPolicy.unsupportedThreshold / 60)) min while idle")
        }
        startAppAttestStallMonitorIfNeeded()
    }

    private func appAttestUnsupportedRestartEligible(_ status: AppAttestLocalStatus?, now: Date) -> Bool {
        AppAttestStallRestartPolicy.unsupportedRestartEligible(
            lastVerifiedAt: appAttestVerifiedMarker().lastVerified(),
            lastRestartAt: appAttestStallRestartMarker().lastRestart(),
            profileExpired: status?.process?.preflight?.profileExpired, now: now,
            relaunchesThroughLaunchd: appAttestRelaunchRoute() == .launchd)
    }

    /// The restart trigger now, or nil when nothing justifies a restart (the
    /// monitor then ends). An Apple stall wins over an unsupported state.
    internal func appAttestRestartTrigger(heldSince: Date?, now: Date) -> AppAttestRestartTrigger? {
        if let heldSince {
            // Held but not yet stalled: keep watching as a stall below threshold.
            return .stalled(seconds: AppleOperationStall.reportedSeconds(heldSince: heldSince, now: now)
                ?? max(0, Int(now.timeIntervalSince(heldSince))))
        }
        guard let since = appAttestUnsupportedSince else { return nil }
        // The state can clear inside the process; Apple's live answer decides.
        guard !appAttestSupportProbe() else {
            logger.info("App Attest: isSupported is true again; no restart needed")
            appAttestUnsupportedSince = nil
            return nil
        }
        return .unsupported(seconds: max(0, Int(now.timeIntervalSince(since))))
    }

    /// Returns whether monitoring should continue.
    private func evaluateAppAttestStallRestart() async -> Bool {
        let now = Date()
        let heldSince = await appAttestShadowClient?.appleOperationHeldSince()
        guard appAttestShadowClient != nil, !isShuttingDown, !Task.isCancelled,
              let trigger = appAttestRestartTrigger(heldSince: heldSince, now: now) else {
            if appAttestStallLastSkip != nil { logger.info("App Attest: restart condition cleared; no restart needed") }
            appAttestStallLastSkip = nil
            publishAppAttestStall(nil)
            appAttestStallMonitorTask = nil
            return false
        }
        if case .stalled(let seconds) = trigger {
            guard Double(seconds) > AppleOperationStall.threshold else { return true }
            publishAppAttestStall(seconds)
        }
        let marker = appAttestStallRestartMarker()
        let decision = AppAttestStallRestartPolicy.decide(
            trigger: trigger, inferenceActive: hasInflightWork || isLoadingAny,
            lifecycleBusy: updatePhase != .idle || servingDrain.refusing || lifecycleDrainTask != nil,
            lastRestartAt: marker.lastRestart(), retryDeferred: appAttestStallRetryDeferred, now: now)
        switch decision {
        case .skip(let reason):
            if reason != appAttestStallLastSkip {
                logger.warning("App Attest: \(Self.describe(trigger)); automatic restart deferred (\(reason.rawValue))")
            }
            appAttestStallLastSkip = reason
            return true
        case .restart:
            return await restartForAppAttest(trigger, marker: marker)
        }
    }

    private static func describe(_ trigger: AppAttestRestartTrigger) -> String {
        switch trigger {
        case .stalled(let seconds): return "Apple operation stalled for \(seconds)s"
        case .unsupported(let seconds): return "isSupported false for \(seconds)s"
        }
    }

    /// Whether the trigger still holds after the drain's last suspension point.
    private func appAttestTriggerStillHolds(_ trigger: AppAttestRestartTrigger, now: Date) async -> Bool {
        switch trigger {
        case .stalled:
            let heldSince = await appAttestShadowClient?.appleOperationHeldSince()
            return AppAttestStallRestartPolicy.stillStalled(heldSince: heldSince, now: now)
        case .unsupported:
            return !appAttestSupportProbe()
        }
    }

    /// Keeps `darkbloom doctor` current between coordinator exchanges.
    private func publishAppAttestStall(_ seconds: Int?) {
        guard var status = appAttestLocalStatus, status.operationStalledSeconds != seconds else { return }
        status.operationStalledSeconds = seconds
        appAttestLocalStatus = status
        writeDaemonState()
    }

    private func restartForAppAttest(_ trigger: AppAttestRestartTrigger, marker: AppAttestStallRestartMarker) async -> Bool {
        let updater = appAttestRestartUpdater ?? SelfUpdater(coordinatorBaseURL: loopConfig.coordinatorURL)
        // The cross-process update lease excludes CLI stop/restart and updates.
        guard claimUpdateStart(updater: updater) else {
            appAttestStallLastSkip = .lifecycleBusy
            return true
        }
        let purpose: String
        switch trigger {
        case .stalled: purpose = "release DeviceCheck admission"
        case .unsupported: purpose = "let a new process launched by launchd read App Attest support again"
        }
        logger.warning("App Attest: \(Self.describe(trigger)); draining for a graceful provider restart to \(purpose) (at most once per \(Int(AppAttestStallRestartPolicy.minimumInterval / 3600))h)")
        beginUpdateDraining()
        guard await waitForSafeDisconnect(timeout: Self.appAttestStallDrainTimeout, reason: "App Attest restart"),
              !Task.isCancelled else {
            logger.warning("App Attest: restart deferred \(Int(AppAttestStallRestartPolicy.drainRetryDelay / 60)) min; accepted work or coordinator acknowledgement is still pending")
            await abandonAppAttestStallRestart(after: .drainNotAcknowledged)
            return true
        }
        // Apple's callback may have arrived, isSupported may be true again, or
        // a CLI stop, OS termination or scheduled shutdown may have taken over
        // the drain, while we awaited. Nothing after the ownership read below
        // suspends, so this is the last point to re-check both.
        let stillHolds = await appAttestTriggerStillHolds(trigger, now: Date())
        let route = appAttestRelaunchRoute()
        // The unsupported restart never falls back to an in-place exec.
        if case .unsupported = trigger, stillHolds, route != .launchd {
            logger.warning("App Attest: restart abandoned; launchd no longer runs this provider")
            appAttestUnsupportedSince = nil
            appAttestStallMonitorTask = nil
            await resumeServingAfterUpdate()
            return false
        }
        let ownsDrain = appAttestStallRestartOwnsDrain && !Task.isCancelled
        switch AppAttestStallRestartPolicy.afterDrain(updateOwnsDrain: ownsDrain, stillBlocked: stillHolds) {
        case .lifecycleTookOver:
            logger.info("App Attest: restart abandoned; a lifecycle drain or shutdown took over")
            appAttestStallMonitorTask = nil
            // Releases the update lease; lifecycle-owned admission stays closed.
            await resumeServingAfterUpdate()
            return false
        case .recovered:
            // App Attest recovered on its own: resume serving without spending
            // the six-hour marker or reloading models.
            logger.info("App Attest: restart condition cleared during drain; resuming without a restart")
            if case .unsupported = trigger { appAttestUnsupportedSince = nil }
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
            logger.warning("App Attest: restart not issued: \(reason)")
            await resumeServingAfterUpdate()
            return true
        }
        usageHistory.flush()
        do {
            try appAttestRestart(.stallRestart, route)
        } catch {
            logger.warning("App Attest: restart failed: \(error)")
            try? updater.cancelPendingCandidateAttempt(operation: "app-attest-stall-restart-failure")
            await resumeServingAfterUpdate()
            return true
        }
        // Reached only when a test seam returns instead of relaunching.
        appAttestStallMonitorTask = nil
        return false
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

    internal func appAttestVerifiedMarker() -> AppAttestVerifiedMarker {
        AppAttestVerifiedMarker(
            directory: (daemonStateFileOverride ?? DaemonStateFile.path()).deletingLastPathComponent())
    }

    /// Records a coordinator-granted App Attest authorization, at most once per
    /// `AppAttestVerifiedMarker.refreshInterval`. A failed write only disables
    /// the unsupported restart; it never affects serving.
    internal func recordAppAttestVerifiedIfGranted(_ authorization: ProviderAuthorizationStatus?, at receivedAt: Double) {
        guard let authorization, authorization.hasCurrentAppAttestAuthorization(now: receivedAt) else { return }
        let now = Date(timeIntervalSince1970: receivedAt)
        if let last = appAttestVerifiedRecordedAt,
           abs(now.timeIntervalSince(last)) < AppAttestVerifiedMarker.refreshInterval { return }
        // Set first: leases renew every few seconds, so a failing write is
        // retried, and logged, once per interval only.
        appAttestVerifiedRecordedAt = now
        do {
            try appAttestVerifiedMarker().record(now)
        } catch {
            logger.warning("App Attest: cannot persist the verified marker: \(error)")
        }
    }
}
