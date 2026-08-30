/// ProviderLoop -- coordinator-authorized release updates.
///
/// Process-evidence-v1 providers never poll "latest" and never select a cohort.
/// The coordinator supplies one exact target/generation; this file reconciles
/// that authorization through the existing verified installer.

import Foundation

extension ProviderLoop {
    static let updateDrainTimeout: Duration = .seconds(120)

    internal func prepareUpdateLifecycleForRun() async throws {
        do {
            updateLifecycle = try UpdateLifecycleReconciler(
                record: try updateLifecycleStore.load())
        } catch {
            updateLifecycleStateCorrupt = true
            logger.error("Release update lifecycle state is unreadable; failing closed")
            state.setUpdateLifecycle(state: .blocked, warmIntent: nil)
            updateAdmissionClosed = true
            return
        }

        let record = updateLifecycle.record
        state.setUpdateLifecycle(
            state: record.state,
            warmIntent: record.reportedWarmIntent)

        switch record.state {
        case .serving:
            updateAdmissionClosed = false
        case .ready:
            guard runningVersionMatches(record.command) else {
                await blockAuthorizedUpdate(
                    "ready release version does not match running application")
                return
            }
            updateAdmissionClosed = false
        case .drainingForUpdate, .installing:
            updateAdmissionClosed = true
            if record.state == .installing,
               runningVersionMatches(record.command) {
                try await transitionUpdateLifecycle(to: .reconnecting)
            } else {
                try await resumeAuthorizedInstallAfterCrash()
            }
        case .reconnecting, .applicationVerifying, .modelReloading:
            updateAdmissionClosed = true
            guard runningVersionMatches(record.command) else {
                await blockAuthorizedUpdate(
                    "installed candidate version does not match authorization")
                return
            }
        case .blocked:
            updateAdmissionClosed = true
        }
    }

    internal var shouldDeferStartupPreloadForUpdate: Bool {
        switch updateLifecycle.record.state {
        case .reconnecting, .applicationVerifying, .modelReloading, .blocked:
            return true
        case .serving, .drainingForUpdate, .installing, .ready:
            return false
        }
    }

    private func runningVersionMatches(
        _ command: AuthorizedReleaseUpdate?
    ) -> Bool {
        guard let command,
              let running = SemanticVersion(ProviderCore.version),
              let target = SemanticVersion(command.version)
        else { return false }
        return running == target
    }

    internal func handleReleaseUpdate(_ command: AuthorizedReleaseUpdate) async {
        guard !updateLifecycleStateCorrupt else {
            logger.error("Refusing release_update while lifecycle state is corrupt")
            return
        }
        guard !isShuttingDown else { return }
        guard command.platform == "macos-arm64" else {
            logger.warning("Refusing release_update for unsupported platform \(command.platform)")
            return
        }
        if let backend = command.backend, backend != "mlx-swift" {
            logger.warning("Refusing release_update for backend \(backend)")
            return
        }
        guard !command.binaryHash.isEmpty, !command.bundleHash.isEmpty,
              !command.url.isEmpty
        else {
            logger.warning("Refusing incomplete release_update authorization")
            return
        }
        guard let artifactURL = URLComponents(string: command.url),
              artifactURL.scheme == "https",
              artifactURL.host != nil,
              artifactURL.user == nil,
              artifactURL.password == nil,
              artifactURL.query == nil,
              artifactURL.fragment == nil
        else {
            logger.warning("Refusing release_update with non-persistable artifact URL")
            return
        }

        let intents = await captureWarmIntents(
            desiredGeneration: command.desiredGeneration)
        do {
            let accepted = try updateLifecycle.authorize(
                command,
                currentVersion: ProviderCore.version,
                warmIntents: intents)
            guard accepted else {
                logger.info(
                    "Ignoring idempotent duplicate release_update generation \(command.desiredGeneration)")
                return
            }

            // No suspension occurs between the successful topology revalidation
            // above and closing admission here.
            updateAdmissionClosed = true
            try await transitionUpdateLifecycle(to: .drainingForUpdate)
        } catch {
            if updateLifecycle.record.command == command {
                await blockAuthorizedUpdate(
                    "authorized generation could not be persisted or published")
            } else {
                logger.warning("Refusing release_update: \(error)")
            }
            return
        }

        let drained = await waitForInflightDrain(timeout: Self.updateDrainTimeout)
        if !drained {
            await cancelAllInflight()
        }
        await installAuthorizedCommandAndRestart()
    }

    internal func handleUpdateConnectionEstablished() async {
        coordinatorConnectionGeneration &+= 1
        evidenceSentConnectionGeneration = nil
        certifiedConnectionGeneration = nil
        pendingCertifiedConnectionGeneration = nil
        guard updateLifecycle.record.state == .reconnecting else { return }
        do {
            try await transitionUpdateLifecycle(to: .applicationVerifying)
        } catch {
            await blockAuthorizedUpdate("could not enter application verification")
        }
    }

    internal func handleFreshApplicationCertification(
        trustLevel: String,
        status: String
    ) async {
        let lifecycleState = updateLifecycle.record.state
        guard lifecycleState == .applicationVerifying ||
                lifecycleState == .modelReloading ||
                lifecycleState == .ready,
              trustLevel == "hardware",
              status == "online",
              UpdateConnectionCertificationPolicy.acceptsEvidence(
                  evidenceGeneration: evidenceSentConnectionGeneration,
                  currentGeneration: coordinatorConnectionGeneration)
        else { return }

        let generation = coordinatorConnectionGeneration
        certifiedConnectionGeneration = generation
        if lifecycleState == .ready {
            try? await publishCurrentUpdateLifecycle()
            return
        }
        if updateWarmRestoreInProgress {
            pendingCertifiedConnectionGeneration = generation
            return
        }
        await finishWarmRestore(certifiedOn: generation)
    }

    private func finishWarmRestore(certifiedOn initialGeneration: UInt64) async {
        updateWarmRestoreInProgress = true
        defer { updateWarmRestoreInProgress = false }
        var certificationGeneration = initialGeneration

        while !isShuttingDown {
            do {
                if updateLifecycle.record.state == .applicationVerifying {
                    try await transitionUpdateLifecycle(to: .modelReloading)
                }
                try await restoreWarmIntentsDeterministically()

                if UpdateConnectionCertificationPolicy.canReportReady(
                    restorationGeneration: certificationGeneration,
                    certifiedGeneration: certifiedConnectionGeneration,
                    currentGeneration: coordinatorConnectionGeneration) {
                    try await transitionUpdateLifecycle(to: .ready)
                    updateAdmissionClosed = false
                    if let send = outboundSend,
                       let entries = deferredDesiredModels.take() {
                        await reconcileDesiredModels(entries, send: send)
                    }
                    return
                }

                guard let pending = pendingCertifiedConnectionGeneration,
                      pending == coordinatorConnectionGeneration,
                      pending == certifiedConnectionGeneration
                else { return }
                pendingCertifiedConnectionGeneration = nil
                certificationGeneration = pending
            } catch {
                await blockAuthorizedUpdate(
                    "application-certified warm restore failed")
                return
            }
        }
    }

    private struct WarmTopologyIdentity: Equatable {
        let modelId: String
        let bridge: ObjectIdentifier
        let modelHash: String?
        let kvBackend: String
    }

    private func warmTopologyIdentity() -> [WarmTopologyIdentity] {
        modelSlots.keys.sorted().compactMap { modelId in
            guard let slot = modelSlots[modelId],
                  !modelsUnloading.contains(modelId)
            else { return nil }
            return WarmTopologyIdentity(
                modelId: modelId,
                bridge: ObjectIdentifier(slot.engineV2),
                modelHash: liveModelHashes[modelId] ?? modelHashes[modelId],
                kvBackend: slot.engineV2.kvBackendKind.rawValue)
        }
    }

    internal func captureWarmIntents(
        desiredGeneration: UInt64
    ) async -> [WarmIntent] {
        while true {
            let topology = warmTopologyIdentity()
            var intents: [WarmIntent] = []
            var remainsValid = true
            for identity in topology {
                guard let slot = modelSlots[identity.modelId],
                      ObjectIdentifier(slot.engineV2) == identity.bridge,
                      !modelsUnloading.contains(identity.modelId)
                else {
                    remainsValid = false
                    break
                }
                let mtp = await slot.engineV2.mtpStatusSnapshot()
                intents.append(WarmIntent(
                    modelId: identity.modelId,
                    modelHash: identity.modelHash,
                    slotId: identity.modelId,
                    kvBackend: identity.kvBackend,
                    kvQuantization: nil,
                    mtpModelId: mtp.assistantModelID,
                    desiredGeneration: desiredGeneration))
            }
            guard remainsValid, topology == warmTopologyIdentity() else {
                continue
            }
            return intents
        }
    }

    private func resumeAuthorizedInstallAfterCrash() async throws {
        guard updateLifecycle.record.command != nil else {
            await blockAuthorizedUpdate(
                "missing authorized command during crash resume")
            return
        }
        if updateLifecycle.record.state == .drainingForUpdate {
            try await transitionUpdateLifecycle(to: .installing)
        }
        await installAuthorizedCommandAndRestart()
    }

    private func installAuthorizedCommandAndRestart() async {
        guard let command = updateLifecycle.record.command else {
            await blockAuthorizedUpdate("missing authorized release")
            return
        }
        do {
            if updateLifecycle.record.state == .drainingForUpdate {
                try await transitionUpdateLifecycle(to: .installing)
            }
            guard updateLifecycle.record.state == .installing else {
                throw UpdateLifecycleError.invalidTransition(
                    from: updateLifecycle.record.state, to: .installing)
            }

            let updater = SelfUpdater(coordinatorBaseURL: loopConfig.coordinatorURL)
            let session = try updater.beginUpdateSession(
                operation: "coordinator-authorized-release-update",
                timeout: 0)
            updateSession = session
            defer {
                updateSession?.release()
                updateSession = nil
            }
            try session.recover()

            let downloaded: URL
            switch await updater.downloadAndVerify(release: command.releaseInfo) {
            case .success(let file): downloaded = file
            case .failure(let error): throw error
            }
            defer { try? FileManager.default.removeItem(at: downloaded) }

            let staged: SelfUpdater.StagedBundle
            switch updater.stageBundle(
                from: downloaded,
                release: command.releaseInfo,
                session: session
            ) {
            case .success(let bundle): staged = bundle
            case .failure(let error): throw error
            }
            stagedUpdateBundle = staged

            switch updater.commitStagedBundle(staged, session: session) {
            case .success:
                stagedUpdateBundle = nil
            case .failure(let error):
                stagedUpdateBundle = nil
                throw error
            }

            try updater.prepareCandidateLaunch(
                session: session,
                baseline: LaunchAgent.launchSnapshot())
            try await transitionUpdateLifecycle(to: .reconnecting)
            session.release()
            updateSession = nil
            try ProcessLifecycle.restartAfterUpdate()
        } catch {
            stagedUpdateBundle?.discard()
            stagedUpdateBundle = nil
            await blockAuthorizedUpdate("verified install/reconnect failed")
            logger.error("Coordinator-authorized release update blocked: \(error)")
        }
    }

    private func restoreWarmIntentsDeterministically() async throws {
        while let intent = updateLifecycle.record.warmIntents.first {
            guard let modelId = intent.modelId else {
                throw UpdateLifecycleError.corruptState
            }
            try await ensureModelLoaded(modelId: modelId)
            guard let slot = modelSlots[modelId] else {
                throw UpdateLifecycleError.corruptState
            }
            if let expectedHash = intent.modelHash,
               liveModelHashes[modelId] != expectedHash {
                throw UpdateError.hashMismatch(
                    expected: expectedHash,
                    got: liveModelHashes[modelId] ?? "missing")
            }
            if let expectedBackend = intent.kvBackend,
               slot.engineV2.kvBackendKind.rawValue != expectedBackend {
                throw UpdateError.replaceFailed(
                    "restored KV backend mismatch for \(modelId)")
            }
            if let expectedMTP = intent.mtpModelId {
                let mtp = await slot.engineV2.mtpStatusSnapshot()
                guard mtp.assistantModelID == expectedMTP else {
                    throw UpdateError.replaceFailed(
                        "restored MTP model mismatch for \(modelId)")
                }
            }
            try updateLifecycle.completeNextWarmIntent(intent)
            try persistUpdateLifecycle()
            try await publishCurrentUpdateLifecycle()
        }
    }

    private func transitionUpdateLifecycle(
        to lifecycleState: UpdateLifecycleState
    ) async throws {
        try updateLifecycle.transition(to: lifecycleState)
        try persistUpdateLifecycle()
        try await publishCurrentUpdateLifecycle()
    }

    private func publishCurrentUpdateLifecycle() async throws {
        guard let coordinatorClient else { return }
        while !isShuttingDown {
            if await coordinatorClient.sendImmediateHeartbeat() { return }
            try await taskSleep(.milliseconds(100))
        }
        throw UpdateError.replaceFailed(
            "provider shut down before lifecycle transition was published")
    }

    private func persistUpdateLifecycle() throws {
        try updateLifecycleStore.save(updateLifecycle.record)
        state.setUpdateLifecycle(
            state: updateLifecycle.record.state,
            warmIntent: updateLifecycle.record.reportedWarmIntent)
    }

    private func blockAuthorizedUpdate(_ reason: String) async {
        updateLifecycle.block()
        updateAdmissionClosed = true
        do {
            try persistUpdateLifecycle()
            try await publishCurrentUpdateLifecycle()
        } catch {
            state.setUpdateLifecycle(
                state: .blocked,
                warmIntent: updateLifecycle.record.reportedWarmIntent)
        }
        logger.error("Release update blocked: \(reason)")
    }
}
