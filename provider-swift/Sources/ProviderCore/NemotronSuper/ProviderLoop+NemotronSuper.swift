// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLMCommon

/// ProviderLoop -- the managed Nemotron Super slot.
///
/// Super has no `ModelContainer` and no generic engine path. `ensureModelLoaded`
/// hands an exact-identity load here after its own selection, eviction and
/// load gates. The KV grant comes from the ordinary re-slice, held under the
/// re-slice gate until the slot is installed; `NemotronSuperLocalLoad` claims
/// LOAD, stages the pinned shards, builds the owner and checks the grant; the
/// slot retires only through its owner. The owner's lane, decode rows and
/// round sit beside its grant and count as resident in every grant. A
/// retained native fault keeps the slot's memory in the fleet budget and
/// refuses later Super loads.
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
        try refuseNemotronSuperReload(modelID)
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
        // Survivors shrink for the planned lane and round before anything is
        // reserved. The owner sizes its plan from its grant with them, the
        // whole fleet budget of a lone slot; publication then shrinks the
        // engine to the grant beside its actual reservations.
        let planned = nemotronSuperPlannedBesideGrantBytes(modelID: modelID)
        let (resident, residentOverflow) = Int(clamping: modelInfo.sizeBytes).addingReportingOverflow(planned)
        let reslice = try await resliceShrinkingForNewcomer(modelId: modelID,
            weightBytes: residentOverflow ? .max : resident, fp16KVBytesPerToken: fp16KVBytesPerToken,
            maxContextLength: NemotronSuperServingPolicy.contextTokens)
        let (room, roomOverflow) = reslice.grantBytes.addingReportingOverflow(planned)
        let kvBytesCapacity = roomOverflow ? Int.max : room
        let plan = nemotronSuperLoadPlan(modelID: modelID, kvBytesCapacity: kvBytesCapacity)
        let owner: NemotronSuperSlotOwner
        do {
            owner = try await nemotronSuperSlotLoader.load(.init(modelID: modelID, directory: directory,
                kvBytesCapacity: kvBytesCapacity, admissionKVBytes: plan.admissionKVBytes,
                defaultMaxTokens: min(Self.schedulerDefaultMaxTokens, NemotronSuperServingPolicy.contextTokens),
                environment: plan.environment, budget: kvBudget,
                physicalBytes: nemotronSuperSlotLoader.physicalBytes))
        } catch {
            // Retained weights stay resident, with the lane, round and bank
            // the plan reserves beside them: survivors keep their shrunk
            // grants until a regrow recomputes with them in the budget.
            if case NemotronSuperSlotError.retainedFault? = error as? NemotronSuperSlotError {
                retainNemotronSuperBytes(Self.saturatingSum(
                    [Int(clamping: modelInfo.sizeBytes), planned, plan.prefixBankBytes]))
            } else {
                await restoreNewcomerReslice(reslice)
            }
            throw error
        }
        let plannedChunk = NemotronSuperLocalPrefill.requestedChunkTokens(environment: plan.environment)
        if let served = owner.fitAttempts.last(where: \.admitted),
            served.requests < plan.requests || served.prefixBankBytes < plan.prefixBankBytes
                || served.chunkTokens < plannedChunk ?? served.chunkTokens {
            let gib = Double(served.claimBytes) / 1_073_741_824
            let lostAfterInstallation = owner.fitAttempts.contains(where: \.lostAfterInstallation)
            logger.warning("""
                Nemotron Super loaded \(served.requests) concurrent request(s), \
                prefix bank \(served.prefixBankBytes > 0 ? "on" : "off"), \(served.chunkTokens)-token prompt chunks \
                (LOAD claim \(String(format: "%.1f", gib)) GiB): the configured policy did not fit available memory\
                \(lostAfterInstallation ? " (a wider owner no longer fit once the weights were installed)" : "")
                """)
        }
        do {
            try await publishNemotronSuperSlot(owner, modelID: modelID, directory: directory,
                modelType: modelInfo.modelType, before: before, started: started)
        } catch {
            if await retireUnpublishedNemotronSuper(owner) { await restoreNewcomerReslice(reslice) }
            throw error
        }
    }

    /// Post-build checks and publication. Caller holds the re-slice gate; a
    /// throw leaves the owner unpublished, for the caller to retire.
    private func publishNemotronSuperSlot(_ owner: NemotronSuperSlotOwner, modelID: String,
        directory: URL, modelType: String?, before: WeightHashSnapshot, started: ContinuousClock.Instant
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
        // Every grant again with the owner's actual reservations resident:
        // its own engine shrinks to what the ledger holds beside them.
        await resliceGrowSurvivorsLocked()
        // The build was checked against its grant with the planned lane and
        // round, which sit beside the grant. Beside other models the grant
        // alone can be too small for one request: such a slot would hold its
        // memory and serve nothing, so it leaves serving and the load fails.
        let grant = await owner.bridge.resliceAdmissionBytesClaim()
        if let refusal = await owner.bridge.superGrantRefusal(grantBytes: grant, requests: 1) {
            logger.error("Nemotron Super serves no request beside the resident models; unloading it: \(refusal)")
            modelSlots.removeValue(forKey: modelID)
            await engineV2Runtime.unregister(modelId: modelID)
            throw refusal
        }
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
    /// retire: its memory stays in the fleet budget and the grants stay shrunk.
    private func retireUnpublishedNemotronSuper(_ owner: NemotronSuperSlotOwner) async -> Bool {
        do {
            try await owner.retire()
            clearCacheAfterConfirmedNativeOwnership()
            return true
        } catch {
            retainNemotronSuperOwner(owner)
            return false
        }
    }

    /// The `unloadModel` path of a Super slot: unregister, drain and close the
    /// owner, then regrow survivors. A retained fault keeps its memory in the
    /// fleet budget; the slot still leaves serving.
    func retireNemotronSuperSlot(_ modelID: String) async -> Bool {
        guard let owner = modelSlots[modelID]?.modelContainer.nemotronSuper,
            !modelsUnloading.contains(modelID) else { return false }
        let deviceActivity = kvBudget.serviceBudget.beginUnboundedActivity()
        defer { deviceActivity.finish() }
        modelsUnloading.insert(modelID)
        await engineV2Runtime.unregister(modelId: modelID)
        let retired: Bool
        do {
            try await owner.retire()
            retired = true
        } catch { retired = false }
        await finishNemotronSuperRetirement(modelID, owner: owner, retired: retired)
        return true
    }

    /// How long a wedged slot's retirement may run: the engine force-finishes
    /// its rows within its own shutdown timeout, and the owner's joins get as
    /// long again. A retirement still running then is a retained fault.
    static let nemotronSuperWedgeRetirementBound: Duration =
        .seconds(2 * CBv2EngineLoopConfig().shutdownTimeout)

    /// A confirmed wedge (`recoverEngineV2SlotIfWedged`). No row of the slot
    /// finishes, so `retireNemotronSuperSlot`'s drain would wait forever on
    /// the capacity tick. The slot leaves serving now; a task of its own shuts
    /// the bridge down first (every pump is cancelled, and the engine
    /// force-finishes its rows within its shutdown timeout), then retires the
    /// owner. Reloads are refused until `engineV2RecoveryCooldown` after `now`.
    /// A retirement past `bound` leaves the owner charged until it completes.
    func retireWedgedNemotronSuperSlot(_ modelID: String, now: ContinuousClock.Instant,
        bound: Duration = ProviderLoop.nemotronSuperWedgeRetirementBound
    ) async {
        guard let owner = modelSlots[modelID]?.modelContainer.nemotronSuper,
            !modelsUnloading.contains(modelID) else { return }
        recordModelLoadError(model: modelID, message: "Nemotron Super slot wedged; retired without a warm rebuild")
        modelsUnloading.insert(modelID)
        engineV2LastRecoveryAt[modelID] = now
        let deviceActivity = kvBudget.serviceBudget.beginUnboundedActivity()
        await engineV2Runtime.unregister(modelId: modelID)
        syncWarmModelState()
        let retirement = Task {
            await owner.bridge.shutdown()
            try await owner.retire()
        }
        Task { [weak self] in
            let retired = await Self.completes(within: bound) { try await retirement.value }
            await self?.finishNemotronSuperRetirement(modelID, owner: owner, retired: retired)
            deviceActivity.finish()
            guard !retired, case .success = await retirement.result else { return }
            await self?.releaseLateRetiredNemotronSuperOwner(owner)
        }
    }

    /// Whether `operation` returns within `bound`; false when it throws or is
    /// still running then. Nothing is cancelled: a retirement that outlives
    /// its bound runs on beside the retained fault.
    private static func completes(within bound: Duration,
        _ operation: @escaping @Sendable () async throws -> Void
    ) async -> Bool {
        let outcome = OneShotBoolContinuation()
        return await withCheckedContinuation { continuation in
            outcome.install(continuation)
            let timer = Task {
                try? await taskSleep(bound)
                outcome.resume(returning: false)
            }
            Task {
                let completed: Bool
                do {
                    try await operation()
                    completed = true
                } catch { completed = false }
                outcome.resume(returning: completed)
                timer.cancel()
            }
        }
    }

    /// The end of every slot retirement: the slot leaves, an owner that did
    /// not retire stays charged, survivors regrow and waiters resume.
    private func finishNemotronSuperRetirement(_ modelID: String, owner: NemotronSuperSlotOwner,
                                               retired: Bool) async {
        if !retired {
            retainNemotronSuperOwner(owner)
            recordModelLoadError(model: modelID, message: "Nemotron Super owner did not retire; "
                + "its memory stays charged until it does or the provider restarts")
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
    }

    /// Native work that did not retire keeps the owner's weights, the
    /// reservations beside its grant and its bank charged in the fleet budget.
    private func retainNemotronSuperOwner(_ owner: NemotronSuperSlotOwner) {
        retainNemotronSuperBytes(Self.retainedChargeBytes(owner))
    }

    /// A wedged retirement that outlived its bound and then completed: the
    /// owner released its native work, reservations and bank after all, so
    /// its charge leaves the fleet budget, and Super loads again unless
    /// another owner stays retained.
    private func releaseLateRetiredNemotronSuperOwner(_ owner: NemotronSuperSlotOwner) async {
        // A saturated total no longer tells this owner's charge apart.
        guard nemotronSuperRetainedWeightBytes < .max else { return }
        nemotronSuperRetainedWeightBytes -= min(nemotronSuperRetainedWeightBytes, Self.retainedChargeBytes(owner))
        logger.info("Nemotron Super owner retired after its bound; its memory is released")
        clearCacheAfterConfirmedNativeOwnership()
        nemotronSuperMemoryRetirement = NativeMemoryRetirementWindow()
        await resliceGrowSurvivors()
        await updateAggregateCapacity()
        await retryReserveDeferredPrefetches()
    }

    private func retainNemotronSuperBytes(_ bytes: UInt64) {
        let (sum, overflow) = nemotronSuperRetainedWeightBytes.addingReportingOverflow(bytes)
        nemotronSuperRetainedWeightBytes = overflow ? .max : sum
    }

    private static func retainedChargeBytes(_ owner: NemotronSuperSlotOwner) -> UInt64 {
        saturatingSum([owner.sizing.weightsBytes, owner.reservedBesideGrantBytes, owner.prefixBankBytes])
    }

    /// The sum of `parts`, negatives as zero, saturating.
    private static func saturatingSum(_ parts: [Int]) -> UInt64 {
        parts.reduce(UInt64(0)) { total, part in
            let (sum, overflow) = total.addingReportingOverflow(UInt64(max(0, part)))
            return overflow ? .max : sum
        }
    }

    /// Super's own slot state refuses a load: native work an earlier owner
    /// retained, until it retires or the process restarts, and a wedged
    /// slot's model until `engineV2RecoveryCooldown` has passed since its
    /// retirement began, never thrashing loads into the fault.
    /// `ensureModelLoaded` asks before it evicts anything for Super and the
    /// load asks again. Transient (503): the coordinator reroutes.
    func refuseNemotronSuperReload(_ modelID: String) throws {
        guard nemotronSuperRetainedWeightBytes == 0 else {
            throw InferenceError.modelLoadFailed("An earlier Nemotron Super owner retained native work; "
                + "refused until it retires or the provider restarts")
        }
        guard nemotronSuperWedgeCooldownActive(modelID) else { return }
        throw InferenceError.modelLoadFailed(
            "Nemotron Super slot wedged; reload refused for \(Self.engineV2RecoveryCooldown) after its retirement")
    }

    /// `fastAdmissionReject`'s verdict on a Super request its slot state
    /// refuses: a load `refuseNemotronSuperReload` refuses, and the wedged
    /// slot itself while it retires, still resident.
    func nemotronSuperRefusesRequest(_ modelID: String) -> Bool {
        guard isNemotronSuperIdentity(modelID) else { return false }
        if nemotronSuperRetainedWeightBytes > 0, modelSlots[modelID] == nil { return true }
        return nemotronSuperWedgeCooldownActive(modelID)
    }

    /// Within `engineV2RecoveryCooldown` of the wedge that began the slot's
    /// retirement (`retireWedgedNemotronSuperSlot`).
    private func nemotronSuperWedgeCooldownActive(_ modelID: String) -> Bool {
        guard let wedged = engineV2LastRecoveryAt[modelID] else { return false }
        return ContinuousClock.now - wedged < Self.engineV2RecoveryCooldown
    }

    /// The pinned owner's planned lane and round (`pinnedOwnerShares`, as its
    /// LOAD claim counts them; neither depends on the grant). Its decode rows
    /// are known once built, and other loaders plan none: publication
    /// re-slices every grant with the owner's actual reservations.
    private func nemotronSuperPlannedBesideGrantBytes(modelID: String) -> Int {
        guard nemotronSuperSlotLoader.pinned else { return 0 }
        let plan = nemotronSuperLoadPlan(modelID: modelID, kvBytesCapacity: 0)
        guard let shares = try? NemotronSuperLocalBridgeBuilder.pinnedOwnerShares(
            environment: plan.environment, kvBytesCapacity: 0, speculates: plan.speculates,
            physicalBytes: nemotronSuperSlotLoader.physicalBytes) else { return 0 }
        let (bytes, overflow) = shares.lane.addingReportingOverflow(shares.round)
        return overflow ? .max : bytes
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
        case NemotronSuperLocalBridgeBuilder.Failure.invalidVideoPruning:
            return "\(NemotronSuperVideoFeatures.pruningKey) is not a rate in [0, 1)"
        case NemotronSuperLocalPrefill.Failure.laneRefused: return "insufficient memory for the prefill lane"
        case NemotronSuperLocalKVBackend.Failure.decodeRowsRefused:
            return "insufficient memory for the decode rows"
        case NemotronSuperLocalPrefixCache.Failure.bankRefused: return "insufficient memory for the prefix bank"
        case NemotronSuperLocalPrefixCache.Failure.unavailable: return "the engine did not construct the prefix bank"
        case NemotronSuperLocalMTP.Failure.roundRefused: return "insufficient memory for the MTP round"
        case NemotronSuperSlotError.retainedFault: return "native work did not retire; restart required"
        default: return nemotronSuperConfigurationRefusal(error) ?? "native construction was refused"
        }
    }

    /// A runtime policy or quote the load refuses before building anything.
    private static func nemotronSuperConfigurationRefusal(_ error: Error) -> String? {
        switch error {
        case NemotronSuperLocalMTP.Failure.invalidDepth:
            return "\(NemotronSuperLocalMTP.depthKey) is not a draft depth the owner serves"
        case NemotronSuperLocalMTP.Failure.invalidVerification:
            return "\(NemotronSuperLocalMTP.verificationKey) is neither rectangular nor serial"
        case NemotronSuperLocalMTP.Failure.loadQuote: return "the speculation head's LOAD quote is invalid"
        case NemotronSuperLocalPrefill.Failure.invalidChunk:
            return "\(NemotronSuperLocalPrefill.chunkKey) is malformed or above the calibrated prefill limit"
        case NemotronSuperLocalPrefill.Failure.invalidDecodeSteps:
            return "\(NemotronSuperLocalPrefill.decodeStepsKey) is malformed or out of range"
        case NemotronSuperLocalKVBackend.Failure.invalidBackend:
            return "\(NemotronSuperLocalKVBackend.key) is neither contiguous nor paged"
        case NemotronSuperLocalBridgeBuilder.Failure.invalidConcurrency:
            return "\(NemotronSuperLocalBridgeBuilder.maxConcurrentKey) is malformed or above what the owner serves"
                + " (one request with serial verification)"
        case NemotronSuperLocalBridgeBuilder.Failure.unsupportedSizing:
            return "the slot sizing or engine configuration is unsupported"
        case NemotronSuperLoadClaim.Failure.invalidQuote: return "the checkpoint's LOAD quote is invalid"
        default: return nil
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return Int64(max(0, ms.rounded()))
    }
}
