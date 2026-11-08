import Foundation

/// StandaloneServer -- background self-update of Only me's background service.
///
/// The cycle `ProviderLoop+AutoUpdate` runs (`AutoUpdateController`): check, then download, verify and stage while
/// serving; then close admission, let this Mac's own requests finish, commit, and restart through launchd into the new
/// release, which the watchdog confirms or rolls back. A drain that doesn't finish in time reopens admission and
/// installs nothing. Only launchd's service runs it; `start --local --here` doesn't.
extension StandaloneServer {
    /// First check five minutes after start, then every 30 minutes, as the network provider does.
    static let autoUpdateInitialDelay: Duration = .seconds(300)
    static let autoUpdateInterval: Duration = .seconds(1800)
    /// How long the owner's requests in flight get to finish before an update waits for the next check.
    static let updateDrainTimeout: Duration = .seconds(120)

    /// Starts the update cycle once; off with `auto_update = false` or `DARKBLOOM_NO_UPDATE_CHECK`.
    public func startAutoUpdateMonitor(coordinatorURL: String, enabled: Bool,
                                       environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard enabled, environment["DARKBLOOM_NO_UPDATE_CHECK"] == nil, autoUpdateTask == nil else { return }
        autoUpdateTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autoUpdateInitialDelay)
            while !Task.isCancelled {
                guard let self else { return }
                await self.performAutoUpdateCheck(coordinatorURL: coordinatorURL)
                try? await Task.sleep(for: Self.autoUpdateInterval)
            }
        }
    }

    /// One update cycle. `updater` and `restart` are test seams; production restarts through launchd.
    @discardableResult
    func performAutoUpdateCheck(
        coordinatorURL: String,
        updater injected: SelfUpdater? = nil,
        restart: @escaping @Sendable () throws -> Void = { try ProcessLifecycle.restartAfterUpdate() }
    ) async -> AutoUpdateController.Outcome {
        let updater = injected ?? SelfUpdater(coordinatorBaseURL: coordinatorURL)
        let deps = AutoUpdateController.Dependencies(
            claimStart: { await self.claimUpdate(updater) },
            resumeServing: { await self.resumeAfterUpdate() },
            check: {
                guard let session = await self.updateSession else {
                    return .checkFailed(reason: "cross-process update lease was lost")
                }
                return await updater.checkForUpdate(session: session)
            },
            downloadVerifyStage: { release in await self.stageUpdate(release, updater: updater) },
            beginDraining: { await self.beginUpdateDrain() },
            waitForDrain: { timeout in await self.waitForUpdateDrain(timeout) },
            commitInstall: { await self.commitStagedUpdate(updater) },
            prepareInstalledRestart: { await self.prepareUpdateRestart(updater) },
            restart: { try restart() },
            restartDidFail: { try? updater.cancelPendingCandidateAttempt(operation: "local-background-restart-failure") },
            log: { standaloneLogger.info("\($0, privacy: .public)") })
        return await AutoUpdateController(deps: deps, drainTimeout: Self.updateDrainTimeout).run()
    }

    /// Claims the cross-process update lease; false while another update, a stop or a drain owns this server.
    private func claimUpdate(_ updater: SelfUpdater) -> Bool {
        guard updateSession == nil, lifecycleState == .running, !lifecycleDraining else { return false }
        do {
            let session = try updater.beginUpdateSession(operation: "local-background-auto-update", timeout: 0)
            try session.recover()
            updateSession = session
            return true
        } catch {
            standaloneLogger.info("Auto-update: update lease unavailable: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Back to serving after a cycle that didn't restart: admission open again, nothing staged, the lease released. A
    /// stop's or restart's drain that arrived meanwhile (`drainForLifecycle`) keeps admission closed: it never reopens.
    func resumeAfterUpdate() {
        if updateDraining {
            updateDraining = false
            if lifecycleCommandID == updateDrainLifecycleCommand, lifecycleState != .stopping {
                lifecycleDraining = false
                responseTracker.setAccepting(true)
            }
        }
        stagedUpdateBundle?.discard()
        stagedUpdateBundle = nil
        updateSession?.release()
        updateSession = nil
    }

    private func stageUpdate(_ release: ReleaseInfo, updater: SelfUpdater) async -> AutoUpdateController.StepOutcome {
        switch await updater.downloadAndVerify(release: release) {
        case .failure(let error):
            return .failed("\(error)")
        case .success(let file):
            defer { try? FileManager.default.removeItem(at: file) }
            guard let session = updateSession else { return .failed("update lease was lost before staging") }
            switch updater.stageBundle(from: file, release: release, session: session) {
            case .success(let staged):
                stagedUpdateBundle = staged
                return .completed
            case .failure(let error):
                return .failed("\(error)")
            }
        }
    }

    /// Admission closes; requests already accepted finish.
    func beginUpdateDrain() {
        updateDraining = true
        updateDrainLifecycleCommand = lifecycleCommandID
        lifecycleDraining = true
        responseTracker.setAccepting(false)
    }

    /// Whether every accepted request finished within `timeout`.
    func waitForUpdateDrain(_ timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while acceptedWork > 0 {
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    /// Requests accepted and not finished, as a lifecycle drain counts them.
    var acceptedWork: Int {
        max(nativeMiMoGracefulWorkCount, max(responseTracker.activeCount, slotReservations.values.reduce(0, +)))
    }

    private func commitStagedUpdate(_ updater: SelfUpdater) -> AutoUpdateController.StepOutcome {
        guard updateDraining, !Task.isCancelled else { return .failed("update cancelled before commit") }
        guard let staged = stagedUpdateBundle, let session = updateSession else {
            return .failed("nothing staged, or the update lease was lost before commit")
        }
        stagedUpdateBundle = nil
        switch updater.commitStagedBundle(staged, session: session) {
        case .success: return .completed
        case .failure(let error): return .failed("\(error)")
        }
    }

    /// Arms the installed release for launchd's restart and releases the lease before it.
    private func prepareUpdateRestart(_ updater: SelfUpdater) -> AutoUpdateController.StepOutcome {
        guard let session = updateSession, updateDraining, !Task.isCancelled else {
            return .failed("update cancelled, or the update lease was lost before the restart")
        }
        do {
            try updater.prepareCandidateLaunch(session: session, baseline: LaunchAgent.launchSnapshot())
            session.release()
            updateSession = nil
            return .completed
        } catch {
            return .failed("\(error)")
        }
    }
}
