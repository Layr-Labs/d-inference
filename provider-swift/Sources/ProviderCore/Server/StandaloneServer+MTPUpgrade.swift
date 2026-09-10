import Foundation
import MLX

/// Retains the old target exactly once while an unregistered, minimal-grant
/// replacement owns only new assistant and KV resources.
final class StagedStandaloneMTPUpgrade: @unchecked Sendable {
    let modelID: String
    // Mutated only by the owning provider actor; cleared before crediting freed weights.
    var original: StandaloneServer.CachedSlot?
    let replacement: ProviderEngineBundle
    let sizing: SlotSizingSnapshot
    let lease: PendingModelLoadLease

    init(modelID: String, original: StandaloneServer.CachedSlot,
         replacement: ProviderEngineBundle, sizing: SlotSizingSnapshot,
         lease: PendingModelLoadLease) {
        self.modelID = modelID
        self.original = original
        self.replacement = replacement
        self.sizing = sizing
        self.lease = lease
    }
}

extension StandaloneServer {
    var mtpStagingBytes: UInt64 {
        mtpStagingReservations.extraBytes(residentTargets: Set(slots.values.map { ObjectIdentifier($0.container) }))
    }

    func isMTPUpgradeTargetRetained(_ modelID: String) -> Bool {
        guard let slot = slots[modelID] else { return false }
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
                        commitIfIdle: { try await self.commitMTPUpgradeIfIdle($0) },
                        discard: { await self.discardMTPUpgrade($0) })
                    if outcome != lastOutcome[modelID], outcome != .installed {
                        await self.logMTPUpgrade("upgrade outcome=\(outcome); retaining current engine", modelID: modelID)
                    }
                    lastOutcome[modelID] = outcome
                    // A single monitor deduplicates GPU preparation. Fetches
                    // are independently bounded/deduplicated by the funnel.
                    nextAttempt[modelID] = .now.advanced(by:
                        outcome == .notReady ? .seconds(15) : .seconds(300))
                }
                do { try await Task.sleep(for: .seconds(Int.random(in: 10...15))) }
                catch { return }
            }
        }
    }

    private func logMTPUpgrade(_ message: String, modelID: String) {
        standaloneLogger.info("mtp: model=\(modelID) \(message)")
    }

    private func pendingMTPUpgradeModels() -> [String] {
        guard lifecycleState == .running,
            SpecDecArtifactFunnel.killSwitchEnabled(environment: ProcessInfo.processInfo.environment)
        else { return [] }
        return slots.compactMap { modelID, slot in
            guard modelID == "gemma-4-26b-qat-4bit", !slot.bundle.mtpStatus.active,
                config.mtpMode.enablesMTP(
                    forModelType: slot.modelType, embeddedArtifactDeclared: false, modelID: modelID),
                !evictingModels.contains(modelID), models.contains(where: { $0.id == modelID })
            else { return nil }
            return modelID
        }.sorted()
    }

    func prepareMTPUpgrade(_ modelID: String, modelDirectory: URL? = nil) async throws -> StagedStandaloneMTPUpgrade? {
        guard pendingMTPUpgradeModels().contains(modelID), !isLoadingAny,
            let target = slots[modelID].map({
                (ObjectIdentifier($0.container), UInt64(max(0, $0.sizing.weightsBytes)))
            }) else { return nil }
        let retention = mtpStagingReservations.retainPreparingTarget(target.0, bytes: target.1)
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
                                          target: ObjectIdentifier) async throws -> StagedStandaloneMTPUpgrade? {
        guard pendingMTPUpgradeModels().contains(modelID), !isLoadingAny,
            let original = slots[modelID], ObjectIdentifier(original.container) == target,
            let info = models.first(where: { $0.id == modelID }),
            let directory = modelDirectory ?? ModelScanner.resolveLocalPath(modelID: modelID)
        else { return nil }
        // Cache misses only schedule the funnel-owned fetch and return. The
        // current engine remains registered and accepts all ordinary traffic.
        let preparation = await specDecPreparation(
            modelId: modelID, modelInfo: info, modelDirectory: directory)
        guard let artifact = preparation.artifact, !isLoadingAny,
            slots[modelID]?.bridge === original.bridge,
            pendingMTPUpgradeModels().contains(modelID)
        else { return nil }
        isLoadingAny = true
        let grant = Int(clamping: EngineV2KVSizing.minimumServiceableGrantBytes)
        guard let lease = await kvBudget.claimPendingLoad(
            requestID: "mtp-upgrade:\(modelID):\(UUID().uuidString)",
            weightBytes: artifact.residentBytes, minimumKVBytes: UInt64(grant))
        else {
            standaloneLogger.warning("mtp: model=\(modelID) assistant staging deferred: insufficient memory; retaining target engine")
            await finishMTPUpgradeLoad()
            throw MTPIdleUpgrade.PreparationError.insufficientMemory
        }
        mtpStagingReservations.reserve(lease, target: ObjectIdentifier(original.container),
            targetBytes: UInt64(max(0, original.sizing.weightsBytes)),
            assistantBytes: artifact.residentBytes, kvBytes: UInt64(grant))
        let preparationStarted = ContinuousClock.now
        var prepared: EngineV2PreparedModel?
        var replacement: ProviderEngineBundle?
        do {
            try Task.checkCancellation()
            guard await kvBudget.recheckPendingLoad(lease) else { throw CancellationError() }
            prepared = try await EngineV2SlotFactory.prepareProductionModel(
                modelId: modelID, isVLM: original.isVLM, modelDirectory: directory,
                container: original.container, specDecPreparation: preparation,
                assistantLoader: v2TestHooks?.assistantLoader ?? ProductionProviderMTPAssistantLoader(),
                emitTelemetry: v2TestHooks?.emitTelemetry,
                logInfo: { standaloneLogger.info("\($0)") }, logWarning: { standaloneLogger.warning("\($0)") })
            guard let prepared, prepared.mtpStatus.active,
                slots[modelID]?.bridge === original.bridge,
                pendingMTPUpgradeModels().contains(modelID)
            else { throw CancellationError() }
            guard await kvBudget.reducePendingLoad(lease, remainingWeightBytes: 0),
                await kvBudget.recheckPendingLoad(lease)
            else { throw CancellationError() }
            let sizing = original.sizing.replacingAuxiliaryWeightBytes(prepared.assistantBytes)
            v2TestHooks?.onCacheEligibleWeightHash?(original.cacheEligibleWeightHash)
            replacement = try await EngineV2SlotFactory.makeProductionBundle(
                modelId: modelID, modelType: original.modelType, isVLM: original.isVLM,
                modelDirectory: directory, container: original.container, tokenizer: original.tokenizer,
                sizing: sizing, kvBytesCapacity: grant,
                maxConcurrentRequests: engineV2MaxConcurrent(forModel: modelID), kvBudget: kvBudget,
                activationReserveBytes: resolvedActivationReserveBytes,
                kvBackendConfig: config.engineV2KVBackend,
                kvBackendConfigByModel: config.engineV2KVBackendByModel,
                prefillDeadlineMode: config.prefillDeadlineMode,
                weightHash: original.cacheEligibleWeightHash,
                specDecPreparation: preparation, preparedModel: prepared,
                startServingTelemetry: false,
                emitTelemetry: v2TestHooks?.emitTelemetry,
                makeEngineOverride: v2TestHooks?.makeEngine,
                logInfo: { standaloneLogger.info("\($0)") },
                logWarning: { standaloneLogger.warning("\($0)") })
            try Task.checkCancellation()
            let replacement = replacement!
            let active: Bool
            if v2TestHooks != nil { active = replacement.mtpStatus.active }
            else { active = await replacement.bridge.mtpStatusSnapshot().active }
            guard active, KVHeadroomProbe.postBuildServeable(
                kvBackendKind: replacement.bridge.kvBackendKind,
                pagedPoolBytes: await replacement.bridge.kvBackendPoolBytes(),
                activationReserveBytes: resolvedActivationReserveBytes)
            else { throw CancellationError() }
            standaloneLogger.info("mtp: model=\(modelID) verified replacement prepared in \(String(describing: preparationStarted.duration(to: .now))); waiting for natural idle")
            await finishMTPUpgradeLoad()
            return StagedStandaloneMTPUpgrade(modelID: modelID, original: original,
                replacement: replacement, sizing: sizing, lease: lease)
        } catch {
            if let replacement { await replacement.bridge.shutdown(); replacement.releaseAssistant() }
            prepared?.assistant?.release()
            prepared = nil
            MLX.Memory.clearCache()
            mtpStagingReservations.release(lease)
            await kvBudget.finishPendingLoad(lease)
            // Preparation still owns the load gate, which serializes reslices.
            await resliceGrowSurvivors()
            standaloneLogger.warning("mtp: model=\(modelID) optional preparation failed: \(String(describing: error)); retaining target engine")
            await finishMTPUpgradeLoad()
            throw error
        }
    }

    func commitMTPUpgradeIfIdle(_ staged: StagedStandaloneMTPUpgrade) async throws -> Bool {
        let modelID = staged.modelID
        guard let original = staged.original else { throw CancellationError() }
        try Task.checkCancellation()
        guard slots[modelID]?.bridge === original.bridge,
            pendingMTPUpgradeModels().contains(modelID)
        else { throw CancellationError() }
        guard slotReservations[modelID, default: 0] == 0, !isLoadingAny else { return false }
        let capacity = await original.bridge.capacitySnapshot()
        try Task.checkCancellation()
        guard capacity.activeRequests == 0, capacity.waitingRequests == 0,
            capacity.kvBytesReserved == 0 else { return false }
        guard slots[modelID]?.bridge === original.bridge,
            pendingMTPUpgradeModels().contains(modelID)
        else { throw CancellationError() }
        guard slotReservations[modelID, default: 0] == 0, !isLoadingAny else { return false }
        isLoadingAny = true
        // No suspension between the last owner check and the admission gate.
        // Work arriving during publication waits; existing work is never drained.
        mtpUpgradeTransitions.insert(modelID)
        slots[modelID] = CachedSlot(
            bundle: staged.replacement, container: original.container,
            tokenizer: original.tokenizer, modelType: original.modelType,
            isVLM: original.isVLM, sizing: staged.sizing,
            lastUsedAt: original.lastUsedAt,
            cacheEligibleWeightHash: original.cacheEligibleWeightHash)
        // Publication is committed. Shutdown of the old idle engine releases
        // its pool before the minimal replacement grant is grown.
        await original.bridge.shutdown()
        original.bundle.releaseAssistant()
        await staged.replacement.bridge.startSSDPrefixCacheStatsLogger()
        await staged.replacement.bridge.configureMTPStatus(staged.replacement.mtpStatus)
        staged.original = nil
        MLX.Memory.clearCache()
        mtpStagingReservations.release(staged.lease)
        await kvBudget.finishPendingLoad(staged.lease)
        await resliceGrowSurvivors()
        // Deferred serving-set updates may wait for or retire this model.
        // End publication before invoking that independent lifecycle work.
        finishMTPUpgradeTransition(modelID)
        await finishMTPUpgradeLoad()
        standaloneLogger.info("mtp: verified assistant installed at idle boundary for \(modelID)")
        return true
    }

    func discardMTPUpgrade(_ staged: StagedStandaloneMTPUpgrade) async {
        await staged.replacement.bridge.shutdown()
        staged.replacement.releaseAssistant()
        staged.original = nil
        MLX.Memory.clearCache()
        // Unlike failed preparation, a staged discard owns no load gate.
        // Wait even when cancelled: resource cleanup must complete, and its
        // regrow must not interleave with a newcomer's shrink/build/install.
        while isLoadingAny {
            await withCheckedContinuation { loadGateWaiters.append($0) }
        }
        isLoadingAny = true
        mtpStagingReservations.release(staged.lease)
        await kvBudget.finishPendingLoad(staged.lease)
        await resliceGrowSurvivors()
        await finishMTPUpgradeLoad()
    }

    private func finishMTPUpgradeLoad() async {
        isLoadingAny = false
        releaseLoadGateWaiters()
        await applyDeferredModelsIfNeeded()
    }

    /// Runs after the preparation frame has released its original/prepared
    /// target references, so a concurrent explicit retirement is accounted
    /// until the last staging owner is actually gone.
    private func finishPreparingMTPUpgrade(_ retention: UUID) async {
        while isLoadingAny {
            await withCheckedContinuation { loadGateWaiters.append($0) }
        }
        isLoadingAny = true
        let previous = mtpStagingBytes
        mtpStagingReservations.releasePreparingTarget(retention)
        if mtpStagingBytes != previous { await resliceGrowSurvivors() }
        await finishMTPUpgradeLoad()
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
