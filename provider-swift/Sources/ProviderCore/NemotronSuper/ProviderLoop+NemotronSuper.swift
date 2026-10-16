// Copyright © 2026 Eigen Labs.

import Foundation
import MLX

/// ProviderLoop -- the managed Nemotron Super slot.
///
/// Super has no `ModelContainer` and no generic engine path. `ensureModelLoaded`
/// hands an exact-identity load here after its own selection, eviction and
/// load gates. The KV grant comes from the ordinary re-slice, held under the
/// re-slice gate until the slot is installed; `NemotronSuperLocalLoad` claims
/// LOAD, stages the pinned shards, builds the owner and checks the grant; the
/// slot retires only through its owner. A retained native fault keeps the
/// slot's weights in the fleet budget and refuses later Super loads.
extension ProviderLoop {
    func isNemotronSuperSlot(_ modelID: String) -> Bool {
        modelSlots[modelID]?.modelContainer.nemotronSuper != nil
    }

    /// The exact Super serving identity of an advertised or resident id.
    func isNemotronSuperIdentity(_ modelID: String) -> Bool {
        NemotronSuperServingPolicy.isServingIdentity(modelID: modelID,
            modelType: advertisedModels[modelID]?.modelType ?? modelSlots[modelID]?.modelType)
    }

    /// Called by `ensureModelLoaded` inside its load gate, after eviction.
    /// Success publishes the slot and finishes the load; a throw has already
    /// released or retained every resource this load took.
    func loadNemotronSuperSlot(modelID: String, directory: URL, modelInfo: ModelInfo,
                               deviceActivity: WholeMacUnboundedActivity) async throws {
        guard nemotronSuperRetainedWeightBytes == 0 else {
            throw InferenceError.modelLoadFailed(
                "An earlier Nemotron Super owner retained native work; process restart required")
        }
        let started = ContinuousClock.now
        let kvRate: Int
        do { kvRate = try nemotronSuperSlotLoader.kvBytesPerToken(directory) }
        catch { throw nemotronSuperLoadFailure(error, modelID: modelID) }
        // The ordinary non-SSD artifact hash policy: publish the pre-load
        // observation; recompute after loading if the snapshot changed.
        let before = try await captureWeightHash(modelId: modelID, modelPath: directory)
        await publishWeightHash(modelId: modelID, snapshot: before)
        if let beforeModelLoad { await beforeModelLoad(modelID) }
        try Task.checkCancellation()
        if isShuttingDown { throw CancellationError() }
        _ = try GPUEnforcement.requireMetal()
        MLXMemoryGuard.configureOnce()

        await acquireResliceGate()
        do {
            try await installNemotronSuperSlot(modelID: modelID, directory: directory,
                modelInfo: modelInfo, fp16KVBytesPerToken: kvRate, before: before, started: started)
        } catch {
            releaseResliceGate()
            throw nemotronSuperLoadFailure(error, modelID: modelID)
        }
        releaseResliceGate()
        syncWarmModelState()
        persistLoadedModelSet()
        let elapsed = started.duration(to: .now)
        recordAutopilotLoadTime(model: modelID, milliseconds: Self.milliseconds(elapsed))
        logger.info("Model loaded: \(modelID) (managed Nemotron Super owner, \(modelSlots.count) model(s) in memory)")
        try await finishModelLoad(modelID: modelID, deviceActivity: deviceActivity)
    }

    /// Re-slice, load and publish. Caller holds the re-slice gate; a throw
    /// has released or retained everything this load took.
    private func installNemotronSuperSlot(modelID: String, directory: URL, modelInfo: ModelInfo,
        fp16KVBytesPerToken: Int, before: WeightHashSnapshot, started: ContinuousClock.Instant
    ) async throws {
        let reslice = try await resliceShrinkingForNewcomer(modelId: modelID,
            weightBytes: Int(clamping: modelInfo.sizeBytes), fp16KVBytesPerToken: fp16KVBytesPerToken,
            maxContextLength: NemotronSuperServingPolicy.contextTokens)
        let plan = nemotronSuperLoadPlan(modelID: modelID, kvBytesCapacity: reslice.grantBytes)
        let owner: NemotronSuperSlotOwner
        do {
            owner = try await nemotronSuperSlotLoader.load(.init(modelID: modelID, directory: directory,
                kvBytesCapacity: reslice.grantBytes, admissionKVBytes: plan.admissionKVBytes,
                defaultMaxTokens: min(Self.schedulerDefaultMaxTokens, NemotronSuperServingPolicy.contextTokens),
                environment: plan.environment, budget: kvBudget,
                physicalBytes: nemotronSuperSlotLoader.physicalBytes))
        } catch {
            // Retained weights stay resident: survivors keep their shrunk
            // grants until a regrow recomputes with them in the budget.
            if case NemotronSuperSlotError.retainedFault? = error as? NemotronSuperSlotError {
                nemotronSuperRetainedWeightBytes += modelInfo.sizeBytes
            } else {
                await restoreNewcomerReslice(reslice)
            }
            throw error
        }
        do {
            try await publishNemotronSuperSlot(owner, modelID: modelID, directory: directory,
                modelType: modelInfo.modelType, before: before, reslice: reslice, started: started)
        } catch {
            if await retireUnpublishedNemotronSuper(owner) { await restoreNewcomerReslice(reslice) }
            throw error
        }
    }

    /// Post-build checks and publication. Caller holds the re-slice gate.
    private func publishNemotronSuperSlot(_ owner: NemotronSuperSlotOwner, modelID: String,
        directory: URL, modelType: String?, before: WeightHashSnapshot, reslice: NewcomerReslice,
        started: ContinuousClock.Instant
    ) async throws {
        // The same measured post-build guard every engine passes.
        clearCacheAfterConfirmedNativeOwnership()
        guard KVHeadroomProbe.postBuildServeable(kvBackendKind: owner.bridge.kvBackendKind,
            pagedPoolBytes: await owner.bridge.kvBackendPoolBytes(),
            activationReserveBytes: resolvedActivationReserveBytes)
        else {
            throw InferenceError.modelLoadFailed(
                "Model '\(modelID)' loaded but left insufficient KV headroom under the memory cap — unloaded")
        }
        var artifactHash = before.hash
        let fingerprint = await Task.detached(priority: .utility) {
            WeightHasher.snapshotFingerprint(snapshotDir: directory)
        }.value
        if before.fingerprint == nil || fingerprint != before.fingerprint {
            let after = try await captureWeightHash(modelId: modelID, modelPath: directory,
                                                    requireFreshCryptographicHash: true)
            await publishWeightHash(modelId: modelID, snapshot: after)
            artifactHash = after.hash
        }
        let status = nemotronSuperMTPStatus(speculates: owner.speculates)
        await owner.bridge.configureMTPStatus(status, metricsInterval: .seconds(60))
        await owner.bridge.recordModelLoadTime(ms: Self.milliseconds(started.duration(to: .now)))
        try Task.checkCancellation()
        guard !isShuttingDown, modelSlots[modelID] == nil, !modelsUnloading.contains(modelID) else {
            throw CancellationError()
        }
        try throwIfRetiring(modelID)
        await engineV2Runtime.register(modelId: modelID, bridge: owner.bridge)
        modelSlots[modelID] = ModelSlot(
            engineBundle: ProviderEngineBundle(bridge: owner.bridge, assistant: nil, assistantBytes: 0,
                mtpArtifact: nil, mtpStatus: status),
            modelContainer: .nemotronSuper(owner), tokenizer: owner.tokenizer, sizing: owner.sizing,
            modelArtifactSHA256: artifactHash, cacheEligibleWeightHash: nil,
            // The owner's image binding serves inline images; generic VLM
            // routes never see this container.
            isVLM: true, modelType: modelType, lastInferenceAt: .now)
        await completeNewcomerReslice(reslice)
    }

    /// Provider policy under this grant: `mtp_mode` and the kill switch pick
    /// speculation; the slot policy's explicit `engine_v2_max_concurrent` bounds
    /// concurrency, else the measured default applies. The slot loader's
    /// pinned-ness and machine memory size the prefix bank exactly as its
    /// builder will.
    func nemotronSuperLoadPlan(modelID: String, kvBytesCapacity: Int) -> NemotronSuperServingPolicy.LoadPlan {
        let backend = loopConfig.config.backend
        let explicit = backend.engineV2MaxConcurrentIsExplicit
            || backend.engineV2MaxConcurrentByModel[modelID] != nil
        return NemotronSuperServingPolicy.loadPlan(
            base: nemotronSuperEnvironment ?? ProcessInfo.processInfo.environment,
            mode: backend.mtpMode,
            configuredConcurrency: explicit ? engineV2MaxConcurrent(forModel: modelID) : nil,
            kvBytesCapacity: kvBytesCapacity, pinned: nemotronSuperSlotLoader.pinned,
            physicalBytes: nemotronSuperSlotLoader.physicalBytes)
    }

    private func nemotronSuperMTPStatus(speculates: Bool) -> MTPActivationStatus {
        if speculates {
            return MTPActivationStatus(configured: true, active: true, reason: nil, source: .inline,
                revision: nil, artifactBytes: 0, assistantBytes: 0)
        }
        return loopConfig.config.backend.mtpMode == .off
            ? .disabled(.configDisabled, configured: false) : .disabled(.killSwitchDisabled, configured: true)
    }

    /// An owner that never became a slot. False when native work did not
    /// retire: its weights stay in the fleet budget and the grants stay shrunk.
    private func retireUnpublishedNemotronSuper(_ owner: NemotronSuperSlotOwner) async -> Bool {
        do {
            try await owner.retire()
            clearCacheAfterConfirmedNativeOwnership()
            return true
        } catch {
            nemotronSuperRetainedWeightBytes += UInt64(max(0, owner.sizing.weightsBytes))
            return false
        }
    }

    /// The `unloadModel` path of a Super slot: unregister, drain and close the
    /// owner, then regrow survivors. A retained fault keeps its weights in the
    /// fleet budget; the slot still leaves serving.
    func retireNemotronSuperSlot(_ modelID: String) async -> Bool {
        guard let slot = modelSlots[modelID], let owner = slot.modelContainer.nemotronSuper,
            !modelsUnloading.contains(modelID) else { return false }
        let deviceActivity = kvBudget.serviceBudget.beginUnboundedActivity()
        defer { deviceActivity.finish() }
        modelsUnloading.insert(modelID)
        await engineV2Runtime.unregister(modelId: modelID)
        var retired = true
        do { try await owner.retire() } catch {
            retired = false
            nemotronSuperRetainedWeightBytes += UInt64(max(0, slot.sizing.weightsBytes))
            recordModelLoadError(model: modelID,
                message: "Nemotron Super owner did not retire; its memory stays charged until restart")
        }
        modelSlots.removeValue(forKey: modelID)
        modelsUnloading.remove(modelID)
        if retired {
            clearCacheAfterConfirmedNativeOwnership()
            nemotronSuperMemoryRetirement = NativeMemoryRetirementWindow()
        }
        await refreshActivationReserve()
        await resliceGrowSurvivors()
        for waiter in unloadingWaiters.removeValue(forKey: modelID) ?? [] { waiter.resume() }
        syncWarmModelState()
        if !isShuttingDown { persistLoadedModelSet() }
        await updateAggregateCapacity()
        logger.info("Unloaded model: \(modelID) (\(modelSlots.count) model(s) remaining)")
        await retryReserveDeferredPrefetches()
        return true
    }

    /// Coordinator-visible load failures stay the transient 503 shape; the
    /// recorded diagnostic names the refusal without paths or payload data.
    /// Cancellation passes through unrecorded.
    private func nemotronSuperLoadFailure(_ error: Error, modelID: String) -> Error {
        if error is CancellationError { return error }
        if case .modelLoadFailed(let message)? = error as? InferenceError {
            recordModelLoadError(model: modelID, message: message)
            return error
        }
        let reason = Self.nemotronSuperLoadRefusalReason(error)
        let message = "Nemotron Super load of '\(modelID)': \(reason)"
        recordModelLoadError(model: modelID, message: message)
        return InferenceError.modelLoadFailed(message)
    }

    /// The recorded reason of a refused Super load: a named refusal for every
    /// failure the load can raise itself, never paths or payload data.
    static func nemotronSuperLoadRefusalReason(_ error: Error) -> String {
        switch error {
        case let refusal as NemotronSuperLocalBridgeBuilder.UnserviceableGrant: return "\(refusal)"
        case let failure as NemotronSuperCheckpoint.Failure: return "\(failure)"
        case NemotronSuperLocalLoad.Failure.capacity: return "insufficient memory at LOAD admission"
        case NemotronSuperLocalLoad.Failure.identity: return "checkpoint identity is not pinned"
        case NemotronSuperLocalBridgeBuilder.Failure.loadAdmissionLost:
            return "the LOAD claim no longer fit after installation"
        case NemotronSuperLocalPrefill.Failure.laneRefused: return "insufficient memory for the prefill lane"
        case NemotronSuperLocalKVBackend.Failure.decodeRowsRefused:
            return "insufficient memory for the decode rows"
        case NemotronSuperLocalPrefixCache.Failure.bankRefused: return "insufficient memory for the prefix bank"
        case NemotronSuperLocalPrefixCache.Failure.unavailable: return "the engine did not construct the prefix bank"
        case NemotronSuperSlotError.retainedFault: return "native work did not retire; restart required"
        default: return "native construction was refused"
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return Int64(max(0, ms.rounded()))
    }
}
