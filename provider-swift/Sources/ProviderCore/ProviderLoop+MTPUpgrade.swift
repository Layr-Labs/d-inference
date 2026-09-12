import Foundation
import MLX

/// Retains the old target exactly once while an unregistered, minimal-grant
/// replacement owns only new assistant and KV resources.
final class StagedProviderMTPUpgrade: @unchecked Sendable {
    let modelID: String
    let drainID = UUID()
    // Mutated only by the owning provider actor; cleared before crediting freed weights.
    var original: ProviderLoop.ModelSlot?
    let replacement: ProviderEngineBundle
    let sizing: SlotSizingSnapshot
    let lease: PendingModelLoadLease

    init(modelID: String, original: ProviderLoop.ModelSlot,
         replacement: ProviderEngineBundle, sizing: SlotSizingSnapshot,
         lease: PendingModelLoadLease) {
        self.modelID = modelID
        self.original = original
        self.replacement = replacement
        self.sizing = sizing
        self.lease = lease
    }
}

extension ProviderLoop {
    var mtpStagingBytes: UInt64 {
        mtpStagingReservations.extraBytes(residentTargets: Set(modelSlots.values.map { ObjectIdentifier($0.container) }))
    }

    func isMTPUpgradeTargetRetained(_ modelID: String) -> Bool {
        guard let slot = modelSlots[modelID] else { return false }
        return mtpStagingReservations.retains(ObjectIdentifier(slot.container))
    }

    func startMTPUpgradeMonitor() {
        guard mtpUpgradeMonitorTask == nil else { return }
        mtpUpgradeMonitorTask = Task { [weak self] in
            var nextAttempt: [String: ContinuousClock.Instant] = [:]
            var lastOutcome: [String: MTPIdleUpgrade.Outcome] = [:]
            while !Task.isCancelled {
                guard let self else { return }
                let candidates = await self.pendingMTPUpgradeModels()
                nextAttempt = nextAttempt.filter { candidates.contains($0.key) }
                for modelID in candidates where !Task.isCancelled {
                    if let next = nextAttempt[modelID], ContinuousClock.now < next { continue }
                    if lastOutcome[modelID] == nil {
                        await self.logMTPUpgrade("checking/downloading verified assistant; target remains available", modelID: modelID)
                    }
                    let outcome = await MTPIdleUpgrade.run(
                        prepare: { try await self.prepareMTPUpgrade(modelID) },
                        waitBeforeDrain: { try await self.waitBeforeMTPUpgradeDrain(modelID) },
                        beginDrain: { try await self.beginMTPUpgradeDrain($0) },
                        commitIfIdle: { try await self.commitMTPUpgradeIfIdle($0) },
                        discard: { await self.discardMTPUpgrade($0) },
                        finishDrain: { await self.finishMTPUpgradeDrain($0) })
                    if outcome != lastOutcome[modelID], outcome != .installed {
                        await self.logMTPUpgrade("upgrade outcome=\(outcome); retaining current engine", modelID: modelID)
                    }
                    lastOutcome[modelID] = outcome
                    // A single monitor deduplicates GPU preparation. Fetches
                    // are independently bounded/deduplicated by the funnel.
                    nextAttempt[modelID] = .now.advanced(by:
                        outcome == .notReady ? .seconds(15) : .seconds(300))
                }
                do { try await taskSleep(.seconds(Int.random(in: 10...15))) }
                catch { return }
            }
        }
    }

    private func logMTPUpgrade(_ message: String, modelID: String) {
        logger.info("mtp: model=\(modelID) \(message)")
    }

    func pendingMTPUpgradeModels() -> [String] {
        guard autopilotCommand == nil, !isShuttingDown, !state.refusingNewWork,
            SpecDecArtifactFunnel.killSwitchEnabled(environment: ProcessInfo.processInfo.environment)
        else { return [] }
        return modelSlots.compactMap { modelID, slot in
            guard modelID == "gemma-4-26b-qat-4bit", !slot.engineBundle.mtpStatus.active,
                loopConfig.config.backend.mtpMode.enablesMTP(
                    forModelType: slot.modelType, embeddedArtifactDeclared: false, modelID: modelID),
                !modelsUnloading.contains(modelID), !isRefusedByRetirement(modelID)
            else { return nil }
            return modelID
        }.sorted()
    }

    func prepareMTPUpgrade(_ modelID: String, modelDirectory: URL? = nil) async throws -> StagedProviderMTPUpgrade? {
        guard pendingMTPUpgradeModels().contains(modelID), !isLoadingAny,
            let target = modelSlots[modelID].map({
                (ObjectIdentifier($0.container), UInt64(max(0, $0.sizing.weightsBytes)))
            }) else { return nil }
        let retention = mtpStagingReservations.retainPreparingTarget(target.0, bytes: target.1)
        await updateAggregateCapacity()
        do {
            let staged = try await prepareRetainedMTPUpgrade(modelID,
                modelDirectory: modelDirectory, target: target.0)
            await finishPreparingMTPUpgrade(retention)
            return staged
        } catch {
            await finishPreparingMTPUpgrade(retention)
            throw error
        }
    }

    private func prepareRetainedMTPUpgrade(_ modelID: String, modelDirectory: URL?,
                                          target: ObjectIdentifier) async throws -> StagedProviderMTPUpgrade? {
        guard pendingMTPUpgradeModels().contains(modelID), !isLoadingAny,
            let original = modelSlots[modelID], ObjectIdentifier(original.container) == target,
            let info = advertisedModels[modelID],
            let directory = modelDirectory ?? ModelScanner.resolveLocalPath(modelID: modelID)
        else { return nil }
        // Cache misses only schedule the funnel-owned fetch and return. The
        // current engine remains registered and accepts all ordinary traffic.
        let preparation = await specDecPreparation(
            modelId: modelID, modelInfo: info, modelDirectory: directory, logStatus: false)
        guard let artifact = preparation.artifact, !isLoadingAny,
            modelSlots[modelID]?.engineV2 === original.engineV2,
            pendingMTPUpgradeModels().contains(modelID)
        else { return nil }
        isLoadingAny = true
        defer { isLoadingAny = false; releaseLoadGateWaiters() }
        let grant = Int(clamping: EngineV2KVSizing.minimumServiceableGrantBytes)
        guard let lease = await kvBudget.claimPendingLoad(
            requestID: "mtp-upgrade:\(modelID):\(UUID().uuidString)",
            weightBytes: artifact.residentBytes, minimumKVBytes: UInt64(grant))
        else {
            logger.warning("mtp: model=\(modelID) assistant staging deferred: insufficient memory; retaining target engine")
            throw MTPIdleUpgrade.PreparationError.insufficientMemory
        }
        await acquireResliceGate()
        mtpStagingReservations.reserve(lease, target: ObjectIdentifier(original.container),
            targetBytes: UInt64(max(0, original.sizing.weightsBytes)),
            assistantBytes: artifact.residentBytes, kvBytes: UInt64(grant))
        await updateAggregateCapacity()
        releaseResliceGate()
        let preparationStarted = ContinuousClock.now
        var prepared: EngineV2PreparedModel?
        var replacement: ProviderEngineBundle?
        do {
            try Task.checkCancellation()
            guard await kvBudget.recheckPendingLoad(lease) else { throw CancellationError() }
            let logger = self.logger
            prepared = try await EngineV2SlotFactory.prepareProductionModel(
                modelId: modelID, isVLM: original.isVLM, modelDirectory: directory,
                container: original.container, specDecPreparation: preparation,
                assistantLoader: engineV2SlotHooks?.assistantLoader ?? ProductionProviderMTPAssistantLoader(),
                emitTelemetry: engineV2SlotHooks?.emitTelemetry,
                logInfo: { logger.info($0) }, logWarning: { logger.warning($0) })
            guard let prepared, prepared.mtpStatus.active,
                modelSlots[modelID]?.engineV2 === original.engineV2,
                pendingMTPUpgradeModels().contains(modelID)
            else { throw CancellationError() }
            guard await kvBudget.reducePendingLoad(lease, remainingWeightBytes: 0),
                await kvBudget.recheckPendingLoad(lease)
            else { throw CancellationError() }
            let sizing = original.sizing.replacingAuxiliaryWeightBytes(prepared.assistantBytes)
            replacement = try await makeEngineV2BundleForSlot(
                modelId: modelID, modelType: original.modelType, isVLM: original.isVLM,
                modelDirectory: directory, container: original.container, tokenizer: original.tokenizer,
                sizing: sizing, kvBytesCapacity: grant, specDecPreparation: preparation,
                preparedModel: prepared, cacheEligibleWeightHash: original.cacheEligibleWeightHash,
                registerInRuntime: false)
            try Task.checkCancellation()
            let replacement = replacement!
            let active: Bool
            if engineV2SlotHooks != nil { active = replacement.mtpStatus.active }
            else { active = await replacement.bridge.mtpStatusSnapshot().active }
            guard active, KVHeadroomProbe.postBuildServeable(
                kvBackendKind: replacement.bridge.kvBackendKind,
                pagedPoolBytes: await replacement.bridge.kvBackendPoolBytes(),
                activationReserveBytes: resolvedActivationReserveBytes)
            else { throw CancellationError() }
            logger.info("mtp: model=\(modelID) verified replacement prepared in \(preparationStarted.duration(to: .now)); ready to drain accepted requests")
            return StagedProviderMTPUpgrade(modelID: modelID, original: original,
                replacement: replacement, sizing: sizing, lease: lease)
        } catch {
            if let replacement { await replacement.bridge.shutdown(); replacement.releaseAssistant() }
            prepared?.assistant?.release()
            prepared = nil
            MLX.Memory.clearCache()
            await releaseMTPStagingAndRegrow(lease)
            logger.warning("mtp: model=\(modelID) optional preparation failed: \(error); retaining target engine")
            throw error
        }
    }

    func commitMTPUpgradeIfIdle(_ staged: StagedProviderMTPUpgrade) async throws -> Bool {
        let modelID = staged.modelID
        guard let original = staged.original else { throw CancellationError() }
        try Task.checkCancellation()
        guard modelSlots[modelID]?.engineV2 === original.engineV2,
            pendingMTPUpgradeModels().contains(modelID)
        else { throw CancellationError() }
        guard !requestToModel.values.contains(modelID), !hasLocalReservation(modelID), !isLoadingAny else {
            return false
        }
        let capacity = await original.engineV2.capacitySnapshot()
        guard capacity.activeRequests == 0, capacity.waitingRequests == 0,
            capacity.kvBytesReserved == 0 else { return false }
        await acquireResliceGate()
        defer { releaseResliceGate() }
        try Task.checkCancellation()
        guard modelSlots[modelID]?.engineV2 === original.engineV2,
            pendingMTPUpgradeModels().contains(modelID)
        else { throw CancellationError() }
        guard !requestToModel.values.contains(modelID), !hasLocalReservation(modelID), !isLoadingAny else {
            return false
        }
        // No suspension between the last owner check and the admission gate.
        // Accepted work has finished; this separate publication gate keeps
        // slot/runtime ownership coherent until replacement cleanup completes.
        mtpUpgradeTransitions.insert(modelID)
        defer { finishMTPUpgradeTransition(modelID) }
        await engineV2Runtime.register(modelId: modelID, bridge: staged.replacement.bridge)
        modelSlots[modelID] = ModelSlot(
            engineBundle: staged.replacement, container: original.container,
            tokenizer: original.tokenizer, sizing: staged.sizing,
            cacheEligibleWeightHash: original.cacheEligibleWeightHash,
            isVLM: original.isVLM, modelType: original.modelType,
            lastInferenceAt: original.lastInferenceAt)
        // Publication is committed. Shutdown of the old idle engine releases
        // its pool before the minimal replacement grant is grown.
        await original.engineV2.shutdown()
        original.engineBundle.releaseAssistant()
        await staged.replacement.bridge.startSSDPrefixCacheStatsLogger()
        await staged.replacement.bridge.configureMTPStatus(staged.replacement.mtpStatus)
        staged.original = nil
        MLX.Memory.clearCache()
        mtpStagingReservations.release(staged.lease)
        await kvBudget.finishPendingLoad(staged.lease)
        await resliceGrowSurvivorsLocked()
        syncWarmModelState()
        await updateAggregateCapacity()
        logger.info("mtp: verified assistant installed at idle boundary for \(modelID)")
        return true
    }

    func discardMTPUpgrade(_ staged: StagedProviderMTPUpgrade) async {
        await staged.replacement.bridge.shutdown()
        staged.replacement.releaseAssistant()
        staged.original = nil
        MLX.Memory.clearCache()
        await releaseMTPStagingAndRegrow(staged.lease)
    }

    private func releaseMTPStagingAndRegrow(_ lease: PendingModelLoadLease) async {
        await acquireResliceGate()
        defer { releaseResliceGate() }
        mtpStagingReservations.release(lease)
        await kvBudget.finishPendingLoad(lease)
        await resliceGrowSurvivorsLocked()
        await updateAggregateCapacity()
    }

    /// Runs after the preparation frame has released its original/prepared
    /// target references, so a concurrent explicit retirement is accounted
    /// until the last staging owner is actually gone.
    private func finishPreparingMTPUpgrade(_ retention: UUID) async {
        await acquireResliceGate()
        defer { releaseResliceGate() }
        let previous = mtpStagingBytes
        mtpStagingReservations.releasePreparingTarget(retention)
        if mtpStagingBytes != previous { await resliceGrowSurvivorsLocked() }
        await updateAggregateCapacity()
    }

    func waitForMTPUpgrade(_ modelID: String) async {
        while mtpUpgradeTransitions.contains(modelID) {
            await withCheckedContinuation { mtpUpgradeWaiters[modelID, default: []].append($0) }
        }
    }

    private func finishMTPUpgradeTransition(_ modelID: String) {
        mtpUpgradeTransitions.remove(modelID)
        let waiters = mtpUpgradeWaiters.removeValue(forKey: modelID) ?? []
        for waiter in waiters { waiter.resume() }
    }
}
