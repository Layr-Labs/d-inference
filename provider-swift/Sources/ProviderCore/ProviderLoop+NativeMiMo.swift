import Foundation
import MLX
import MLXLMCommon
import ProviderCoreFoundation

/// Retry hints only. None of these counts is a completion or memory-credit
/// oracle; only the registered transaction can retire its actual native owner.
struct NativeMiMoRetirementProgress: Equatable {
    let phase: String
    let operations: Int
    let constructionEpoch: UInt64
    let constructionFailed: Bool
    let hostOwners: [Int]
}

struct NativeMiMoShutdownIdentity: Equatable {
    let engineID: UUID
    let contractID: UUID
    func matches(_ receipt: CBv2NativeShutdownReceipt) -> Bool {
        receipt.engineID == engineID && receipt.executionContractID == contractID && receipt.generation == 1
    }
}

extension ProviderLoop {
    nonisolated static func nativeProcessAllowsReclamation() -> Bool {
        let registry = MiMoV26NativeLoadRegistry.shared
        return !registry.hasRetainedFault && !registry.hasUnretiredClosingTransactions
    }

    func nativeMiMoAllowsReclamation() -> Bool {
        Self.nativeProcessAllowsReclamation()
            && !nativeMiMoRegistry.hasRetainedFault
            && !nativeMiMoRegistry.hasUnretiredClosingTransactions
    }

    /// Preserve the existing allocator operation, but never use a pending or
    /// faulted native owner's future release as permission to reclaim/regrow.
    func clearCacheAfterConfirmedNativeOwnership() {
        guard nativeMiMoAllowsReclamation() else { return }
        MLX.Memory.clearCache()
    }

    func requireNativeMiMoProcessWorkAllowed() throws {
        try MiMoV26NativeLoadRegistry.shared.requireNewNativeWorkAllowed()
        try nativeMiMoRegistry.requireNewNativeWorkAllowed()
    }

    func nativeMiMoLifecycleForLoad() throws -> MiMoV26NativeLifecycle {
        try requireNativeMiMoProcessWorkAllowed()
        // Existing authoritative request admission gates stop new work during
        // a graceful drain. Like the generic loader, an already accepted cold
        // load may finish; actual stop/force still closes this generation.
        guard !nativeMiMoLifecycleClosed, !isShuttingDown else {
            throw CancellationError()
        }
        if let nativeMiMoLifecycle { return nativeMiMoLifecycle }
        let lifecycle = try nativeMiMoRegistry.openLifecycle()
        nativeMiMoLifecycle = lifecycle
        return lifecycle
    }

    /// Synchronous actor transition, called at stop entry before the first
    /// await. Even an owner that has never loaded cannot mint a later lifecycle.
    func closeNativeMiMoLifecycle() {
        guard !nativeMiMoLifecycleClosed else { return }
        nativeMiMoLifecycleClosed = true
        if let lifecycle = nativeMiMoLifecycle {
            do { nativeMiMoLifecycle = try nativeMiMoRegistry.closeLifecycle(lifecycle) }
            catch { logger.error("Native MiMo owner lifecycle could not be closed; retirement required") }
        }
        for load in nativeMiMoLoads.values { load.revoke() }
        // Do not cancel accepted serving leases here: graceful lifecycle drain
        // lets active requests finish. Actual retirement/force closes them below.
    }

    /// Stop/retry control, not a deadline-based receipt. Each successful removal
    /// below follows the actual transaction's proof and external consumer joins.
    func drainNativeMiMoOwners() async -> Bool {
        closeNativeMiMoLifecycle()
        let slotIDs = modelSlots.keys.filter {
            modelSlots[$0].flatMap({ Self.nativeMiMoLoad(in: $0.modelContainer) }) != nil
        }
        var finished = true
        for modelID in Set(nativeMiMoLoads.keys).union(slotIDs) {
            if !(await retireNativeMiMoOwner(modelID: modelID)) { finished = false }
        }
        return finished
    }

    nonisolated static func nativeMiMoLoad(in container: ProviderModelContainer) -> MiMoV26ServingLoad? {
        if case .nativeMiMo(_, let load) = container { return load }
        return nil
    }

    func requireResidentNativeMiMoOwner(_ modelID: String) throws {
        guard let slot = modelSlots[modelID], let load = Self.nativeMiMoLoad(in: slot.modelContainer) else { return }
        guard let transaction = load.transaction else { throw MiMoV26ServingLoadError.nativeOwnerMismatch }
        try transaction.requireServingWorkAllowed()
    }

    /// Per actual acquisition, not request-name inference. Native identity must
    /// match this exact live container/bridge and published transaction. Store
    /// the same lease before the scheduler/acquirer can return or start work.
    func nativeMiMoConsumerLease(
        modelID: String, entry: MultiModelBatchSchedulerEngine.ModelRegistryEntry
    ) throws -> NativeLocalConsumerLease? {
        let load = modelSlots[modelID].flatMap { Self.nativeMiMoLoad(in: $0.modelContainer) }
        guard let load else {
            if entry.modelType == "mimo_v2" { throw MiMoV26ServingLoadError.nativeOwnerMismatch }
            return nil
        }
        guard !nativeMiMoLifecycleClosed, !modelsUnloading.contains(modelID),
            nativeMiMoLoads[modelID] === load, let transaction = load.transaction,
            let slot = modelSlots[modelID], let actual = slot.container,
            actual === entry.container, slot.engineV2 === entry.engineV2Bridge else {
            throw MiMoV26ServingLoadError.nativeOwnerMismatch
        }
        try requireNativeMiMoProcessWorkAllowed()
        try transaction.requireServingWorkAllowed()
        try transaction.validateContainerIdentity(actual)
        // Drop completed metadata at a safe admission boundary. Completion is
        // the lease's actual task/callback result, never a numeric pin count.
        nativeMiMoConsumerLeases[modelID] = nativeMiMoConsumerLeases[modelID]?.filter { id, lease in
            let value = lease.snapshot()
            let keep = value.phase != .completed && value.phase != .abandoned
            if !keep { nativeMiMoClosedConsumerLeaseIDs.remove(id) }
            return keep
        }
        let lease = NativeLocalConsumerLease()
        nativeMiMoConsumerLeases[modelID, default: [:]][lease.id] = lease
        return lease
    }

    private func closeNativeMiMoConsumerLeases(_ modelID: String) {
        for lease in nativeMiMoConsumerLeases[modelID].map({ Array($0.values) }) ?? [] {
            guard nativeMiMoClosedConsumerLeaseIDs.insert(lease.id).inserted else { continue }
            let state = lease.snapshot()
            if state.phase != .completed && state.phase != .abandoned { lease.closeAndCancel() }
        }
    }

    /// Store the facade before the real permit claim: the core installs its
    /// transaction before that claim can fail, and failure must still be owned.
    @discardableResult
    func claimNativeMiMoLoad(_ load: MiMoV26ServingLoad, modelID: String) throws -> MiMoV26NativeLoadTransaction {
        guard nativeMiMoLoads[modelID] == nil, modelSlots[modelID] == nil, load.transaction == nil else {
            throw MiMoV26NativeTransactionError.warmRebuildUnsupported
        }
        guard nativeMiMoAllowsReclamation() else {
            throw InferenceError.modelLoadFailed("Native MiMo slot retirement is pending")
        }
        let lifecycle = try nativeMiMoLifecycleForLoad()
        nativeMiMoLoads[modelID] = load
        try load.claim(budget: kvBudget, lifecycle: lifecycle, registry: nativeMiMoRegistry)
        guard let transaction = load.transaction else { throw MiMoV26ServingLoadError.nativeOwnerMismatch }
        return transaction
    }

    /// Native-only extraction: no path below can enter generic Void-shutdown,
    /// newcomer release, assistant fallback/rebuild or speculative grant restore.
    func loadNativeMiMoSlot(modelID: String, directory: URL, load: MiMoV26ServingLoad,
                           preparation: SpecDecPreparation) async throws {
        // Refuse a duplicate/warm call before installing cancellation handling:
        // a cancelled duplicate must not revoke somebody else's live pipeline.
        guard nativeMiMoLoads[modelID] == nil, modelSlots[modelID] == nil, load.transaction == nil else {
            throw MiMoV26NativeTransactionError.warmRebuildUnsupported
        }
        try await withTaskCancellationHandler {
            try await performNativeMiMoSlotLoad(modelID: modelID, directory: directory,
                                                load: load, preparation: preparation)
        } onCancel: {
            // Covers synchronous claim/prewarm as well as the later owned Task.
            // The facade latches cancellation even before a TX is installed.
            load.revoke()
        }
    }

    private func performNativeMiMoSlotLoad(modelID: String, directory: URL, load: MiMoV26ServingLoad,
                                          preparation: SpecDecPreparation) async throws {
        do {
            let transaction = try claimNativeMiMoLoad(load, modelID: modelID)
            let task = try nativeMiMoRegistry.launchOwnedTask(for: transaction) {
                try await transaction.performSetup {
                    try await self.prepareNativeMiMoSlot(modelID: modelID, directory: directory,
                                                         load: load, preparation: preparation)
                }
                // Keep this actual registry-owned Task through seal, the final
                // actor gate and publication. The setup operation must unwind
                // before seal, but its controller must not become unowned.
                try await self.publishNativeMiMoCandidate(modelID: modelID, load: load, transaction: transaction)
            }
            try await withTaskCancellationHandler {
                try await task.value
                // This actor caller is outside the registry-owned setup task.
                await nativeMiMoRegistry.joinOwnedTasksFromOutside(transaction)
                try Task.checkCancellation()
                try transaction.requireServingWorkAllowed()
            } onCancel: {
                task.cancel()
                transaction.revoke()
            }
        } catch {
            // Duplicate/warm refusal must not revoke an already serving pipeline.
            if let refusal = error as? MiMoV26NativeTransactionError,
                refusal == .warmRebuildUnsupported || refusal == .slotAssemblyAlreadyClaimed {
                throw error
            }
            load.revoke()
            if let transaction = load.transaction {
                await nativeMiMoRegistry.joinOwnedTasksFromOutside(transaction)
            }
            let retired = await retireNativeMiMoOwner(modelID: modelID)
            if let transaction = load.transaction,
                nativeMiMoResliceOwners.remove(transaction.id) != nil { releaseResliceGate() }
            if !retired {
                throw InferenceError.modelLoadFailed(nativeMiMoRegistry.hasRetainedFault
                    ? "Native MiMo slot completion failed; process restart required"
                    : "Native MiMo slot retirement is pending")
            }
            if error is CancellationError { throw CancellationError() }
            // Never reflect SDK path/payload/native failure descriptions onto
            // coordinator/public error surfaces through generic load catch code.
            throw InferenceError.modelLoadFailed("Native MiMo slot construction was refused")
        }
    }

    private func publishNativeMiMoCandidate(modelID: String, load: MiMoV26ServingLoad,
                                             transaction: MiMoV26NativeLoadTransaction) async throws {
        guard let candidate = nativeMiMoCandidates[modelID] else { throw MiMoV26ServingLoadError.nativeOwnerMismatch }
        try requireNativeMiMoPublication(modelID: modelID, load: load)
        _ = try await load.sealConstructionForPublication()
        try await nativeMiMoBoundaryForTesting?("beforePublication")
        try Task.checkCancellation()
        try requireNativeMiMoPublication(modelID: modelID, load: load)
        // Actual insertion, not a caller Boolean, occurs under the core's
        // lifecycle/fault/permit lock. No await or core reentry in callback.
        try load.commitPublication { modelSlots[modelID] = candidate }
        nativeMiMoCandidates.removeValue(forKey: modelID)
        // This post-publication handoff stays in the same real owned Task.
        await engineV2Runtime.register(modelId: modelID, bridge: candidate.engineV2)
        try Task.checkCancellation()
        try transaction.requireServingWorkAllowed()
        if nativeMiMoResliceOwners.remove(transaction.id) != nil { releaseResliceGate() }
    }

    private func requireNativeMiMoPublication(modelID: String, load: MiMoV26ServingLoad) throws {
        try requireNativeMiMoProcessWorkAllowed()
        guard !isShuttingDown, !nativeMiMoLifecycleClosed,
            nativeMiMoLoads[modelID] === load, modelSlots[modelID] == nil else { throw CancellationError() }
        try throwIfRetiring(modelID)
        try load.recheck()
    }

    private func prepareNativeMiMoSlot(modelID: String, directory: URL, load: MiMoV26ServingLoad,
                                       preparation: SpecDecPreparation) async throws {
        guard engineV2SlotHooks == nil else { throw MiMoV26ServingLoadError.nativeOwnerMismatch }
        let started = ContinuousClock.now
        try requireNativeMiMoPublication(modelID: modelID, load: load)
        let reusableSSD = PrefixCachePolicy.isEnabled(modelId: modelID)
        let before = try await captureWeightHash(modelId: modelID, modelPath: directory,
                                                 requireFreshCryptographicHash: reusableSSD)
        if !reusableSSD { await publishWeightHash(modelId: modelID, snapshot: before) }
        if let beforeModelLoad { await beforeModelLoad(modelID) }
        try Task.checkCancellation()
        try requireNativeMiMoPublication(modelID: modelID, load: load)
        _ = try GPUEnforcement.requireMetal()
        MLXMemoryGuard.configureOnce()
        let container = try await ModelContainerLoading.loadServingContainer(
            from: directory, modelID: modelID, nativeMiMoLoad: load)
        // The corrected core already holds this same raw container before its
        // return; no untracked alias or substitute container is manufactured.
        let newcomer = EngineV2NewcomerBox(container)
        try Task.checkCancellation()
        try requireNativeMiMoPublication(modelID: modelID, load: load)
        let cacheHash: String?
        if reusableSSD {
            let after = try await captureWeightHash(modelId: modelID, modelPath: directory,
                                                    requireFreshCryptographicHash: true)
            switch Self.reusableSSDWeightHashDecision(preLoadHash: before.hash, postLoadHash: after.hash) {
            case .eligible(let value):
                await publishWeightHash(modelId: modelID, snapshot: after); cacheHash = value
            case .unavailable:
                await markWeightHashUnavailable(modelId: modelID); cacheHash = nil
            case .changed:
                throw InferenceError.modelLoadFailed("Native MiMo slot artifact changed during loading")
            }
        } else {
            // Same existing non-SSD fingerprint/hash policy; this detached task
            // is joined immediately and does no native/model construction.
            let fingerprint = await Task.detached(priority: .utility) {
                WeightHasher.snapshotFingerprint(snapshotDir: directory)
            }.value
            try Task.checkCancellation()
            if before.fingerprint == nil || fingerprint != before.fingerprint {
                let after = try await captureWeightHash(modelId: modelID, modelPath: directory,
                                                        requireFreshCryptographicHash: true)
                await publishWeightHash(modelId: modelID, snapshot: after)
            }
            cacheHash = nil
        }
        let sizing = await container.sizing(modelPath: directory, defaultMaxTokens: Self.schedulerDefaultMaxTokens)
        try requireNativeMiMoPublication(modelID: modelID, load: load)
        clearCacheAfterConfirmedNativeOwnership()
        guard KVHeadroomProbe.hasServeableKVHeadroom(activationReserveBytes: resolvedActivationReserveBytes) else {
            throw InferenceError.modelLoadFailed("Native MiMo slot has insufficient measured KV headroom")
        }
        let tokenizer = await container.tokenizerHandle(modelType: "mimo_v2", directory: directory)
        try requireNativeMiMoPublication(modelID: modelID, load: load)
        await acquireResliceGate()
        guard let transaction = load.transaction else { releaseResliceGate(); throw MiMoV26ServingLoadError.nativeOwnerMismatch }
        nativeMiMoResliceOwners.insert(transaction.id)
        try requireNativeMiMoPublication(modelID: modelID, load: load)
        let build = try await resliceAndBuildEngineV2Bundle(
            modelId: modelID, modelType: "mimo_v2", isVLM: false, modelDirectory: directory,
            newcomer: newcomer, tokenizer: tokenizer, targetSizing: sizing,
            specDecPreparation: preparation, cacheEligibleWeightHash: cacheHash, registerInRuntime: false)
        // Factory/core registerBundle must retain this exact owner before its
        // return, including an outer performSetup veto after this method returns.
        try await nativeMiMoBoundaryForTesting?("afterNativeConstruction")
        try requireNativeMiMoPublication(modelID: modelID, load: load)
        clearCacheAfterConfirmedNativeOwnership()
        let serveable = KVHeadroomProbe.postBuildServeable(
            kvBackendKind: build.bundle.bridge.kvBackendKind,
            pagedPoolBytes: await build.bundle.bridge.kvBackendPoolBytes(),
            activationReserveBytes: resolvedActivationReserveBytes)
        let actualMTP = await build.bundle.bridge.mtpStatusSnapshot().active
        let wantsMTP = preparation.status.configured && preparation.status.reason == nil
        guard serveable, !wantsMTP || (build.bundle.mtpStatus.active && actualMTP),
            !build.bundle.mtpStatus.active || actualMTP else {
            // Native pipeline construction is one-shot. Refuse before any
            // destructive assistant release or target-only second engine.
            throw InferenceError.modelLoadFailed("Native MiMo slot post-build validation failed")
        }
        let elapsed = started.duration(to: .now)
        let milliseconds = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        await build.bundle.bridge.recordModelLoadTime(ms: Int64(max(0, milliseconds.rounded())))
        try Task.checkCancellation()
        try requireNativeMiMoPublication(modelID: modelID, load: load)
        // The owned Task returns Void: its cached Task.result cannot retain a
        // hidden model/slot alias after the external owner joins and drops it.
        nativeMiMoCandidates[modelID] = ModelSlot(
            engineBundle: build.bundle, modelContainer: container, tokenizer: tokenizer,
            sizing: build.sizing, cacheEligibleWeightHash: cacheHash, isVLM: false,
            modelType: "mimo_v2", lastInferenceAt: .now)
    }

    func refuseClosingNativeMiMoOwner(_ modelID: String) throws {
        if nativeMiMoRetiring.contains(modelID) || nativeMiMoPendingRetirements[modelID] != nil {
            throw InferenceError.modelLoadFailed("Native MiMo slot retirement is pending")
        }
    }

    func nativeMiMoRefusesRequest(_ modelID: String) -> Bool {
        do {
            try requireNativeMiMoProcessWorkAllowed()
            try refuseClosingNativeMiMoOwner(modelID)
            try requireResidentNativeMiMoOwner(modelID)
            return modelSlots[modelID] == nil && !nativeMiMoAllowsReclamation()
        } catch { return true }
    }

    func finishNativeMiMoSlotPublication(modelID: String) async throws {
        try requireResidentNativeMiMoOwner(modelID)
        syncWarmModelState()
        persistLoadedModelSet()
        await updateAggregateCapacity()
        try Task.checkCancellation()
        try requireResidentNativeMiMoOwner(modelID)
        modelsLoading.remove(modelID)
        isLoadingAny = false
        for waiter in loadingWaiters.removeValue(forKey: modelID) ?? [] { waiter.resume() }
        releaseLoadGateWaiters()
        await retryReserveDeferredPrefetches()
    }

    func finishNativeMiMoLoadFailure(modelID: String, load: MiMoV26ServingLoad, error: Error) async {
        if nativeMiMoLoads[modelID] === load {
            load.revoke()
            if let transaction = load.transaction {
                await nativeMiMoRegistry.joinOwnedTasksFromOutside(transaction)
            }
            _ = await retireNativeMiMoOwner(modelID: modelID)
            if let transaction = load.transaction,
                nativeMiMoResliceOwners.remove(transaction.id) != nil { releaseResliceGate() }
        }
        // A pending/faulted native owner remains in nativeMiMoLoads and the
        // reserve basis. Metadata load waiters may fail without freeing C.
        if nativeMiMoLoads[modelID] == nil { modelsLoading.remove(modelID) }
        isLoadingAny = false
        for waiter in loadingWaiters.removeValue(forKey: modelID) ?? [] { waiter.resume(throwing: error) }
        releaseLoadGateWaiters()
        if nativeMiMoAllowsReclamation() {
            await refreshActivationReserve()
            await resliceGrowSurvivors()
            await retryReserveDeferredPrefetches()
        }
    }

    /// Handoff before a native request's ordinary map entry disappears. The
    /// watcher retains its real Task until Task.value, not until cancellation or
    /// a terminal counter. It never self-awaits the request that created it.
    func retainNativeMiMoHostConsumer(_ task: Task<Void, Never>, modelID: String) {
        guard nativeMiMoLoads[modelID] != nil
            || modelSlots[modelID].flatMap({ Self.nativeMiMoLoad(in: $0.modelContainer) }) != nil else { return }
        let transactionID = (nativeMiMoLoads[modelID]
            ?? modelSlots[modelID].flatMap({ Self.nativeMiMoLoad(in: $0.modelContainer) }))?.transaction?.id
        let identity = UUID()
        nativeMiMoHostConsumers[modelID, default: [:]][identity] = task
        nativeMiMoHostConsumerWatchers[identity] = Task { [weak self] in
            await task.value
            await self?.finishedNativeMiMoHostConsumer(modelID: modelID, identity: identity, transactionID: transactionID)
        }
    }

    private func finishedNativeMiMoHostConsumer(modelID: String, identity: UUID, transactionID: UUID?) {
        nativeMiMoHostConsumers[modelID]?.removeValue(forKey: identity)
        if nativeMiMoHostConsumers[modelID]?.isEmpty == true { nativeMiMoHostConsumers.removeValue(forKey: modelID) }
        nativeMiMoHostConsumerWatchers.removeValue(forKey: identity)
        if let transactionID, nativeMiMoLoads[modelID]?.transaction?.id == transactionID {
            nativeMiMoRetirementReady.insert(modelID)
        }
    }

    /// External control path. Setup Tasks join first. For serving Tasks, drive
    /// the exact typed bridge drain first: their cancel settlement can itself
    /// await SDK/bridge retirement. Only then may their actual Task.value joins
    /// precede the transaction's FINAL cleanup/permit retirement.
    @discardableResult
    func retireNativeMiMoOwner(modelID: String) async -> Bool {
        guard !nativeMiMoRetiring.contains(modelID) else { return false }
        guard let load = nativeMiMoLoads[modelID]
            ?? modelSlots[modelID].flatMap({ Self.nativeMiMoLoad(in: $0.modelContainer) }) else { return true }
        nativeMiMoLoads[modelID] = load
        nativeMiMoRetiring.insert(modelID)
        defer { nativeMiMoRetiring.remove(modelID) }
        load.revoke()
        closeNativeMiMoConsumerLeases(modelID)
        modelsUnloading.insert(modelID)
        guard let transaction = load.transaction else {
            guard modelSlots[modelID] == nil, nativeMiMoCandidates[modelID] == nil else {
                nativeMiMoPendingRetirements[modelID] = .init(
                    phase: "missingOwner", operations: 0, constructionEpoch: 0,
                    constructionFailed: false, hostOwners: [])
                return false
            }
            // The facade was stored before claim. No transaction means the
            // synchronous claim failed before any setup Task/native work began.
            nativeMiMoLoads.removeValue(forKey: modelID)
            modelsUnloading.remove(modelID)
            return true
        }
        await nativeMiMoRegistry.joinOwnedTasksFromOutside(transaction)
        let before = transaction.snapshot()
        let hadNativePayload = before.hasContainer || before.hasEngine || before.hasBundle
            || (try? transaction.currentConstructionReceipt().completion) == .capturedStreamsCompleted
        if before.activeOperations != 0 {
            await rememberNativeMiMoPending(modelID: modelID, transaction: transaction)
            return false
        }
        if before.constructionFailed {
            _ = await transaction.retire() // classify/retain, never caller cleanup
            await rememberNativeMiMoPending(modelID: modelID, transaction: transaction, watchConsumers: false)
            return false
        }
        let bridge = transaction.registeredBridgeForRetirement()
        if let bridge {
            do {
                // Validate this owner's current completed SDK construction
                // before requesting a preliminary drain. Final retirement still
                // revalidates its work/contract/proof inside the transaction.
                _ = try transaction.currentConstructionReceipt()
                let outcome: CBv2NativeShutdownOutcome
                if let engine = await bridge.ownedEngine as? EngineV2,
                    let contract = engine.nativeShutdownExecutionContractID {
                    let identity = NativeMiMoShutdownIdentity(engineID: engine.nativeShutdownEngineID, contractID: contract)
                    guard nativeMiMoShutdownIdentities[transaction.id] == nil
                        || nativeMiMoShutdownIdentities[transaction.id] == identity else {
                        await rememberNativeMiMoPending(modelID: modelID, transaction: transaction, watchConsumers: false)
                        return false
                    }
                    nativeMiMoShutdownIdentities[transaction.id] = identity
                    outcome = try await bridge.shutdownNativeConstruction(
                        expectedEngine: engine, executionContractID: contract)
                } else if let completed = await bridge.nativeShutdownResult {
                    outcome = completed
                } else {
                    await rememberNativeMiMoPending(modelID: modelID, transaction: transaction)
                    return false
                }
                if case .incomplete = outcome {
                    _ = await transaction.retire() // actual core seals the process fault
                    await rememberNativeMiMoPending(modelID: modelID, transaction: transaction, watchConsumers: false)
                    return false
                }
                guard case .quiescent(let receipt) = outcome,
                    nativeMiMoShutdownIdentities[transaction.id]?.matches(receipt) == true else {
                    await rememberNativeMiMoPending(modelID: modelID, transaction: transaction, watchConsumers: false)
                    return false
                }
                try await nativeMiMoBoundaryForTesting?("afterSDKDrainBeforeHostJoin")
            } catch {
                await rememberNativeMiMoPending(modelID: modelID, transaction: transaction)
                return false
            }
        }
        // These are actual Tasks, not task-count/terminal observations. A native
        // load setup Task is never in these maps; all calls here are external.
        let liveTasks = inflightTasks.compactMap { requestID, task in
            requestToModel[requestID] == modelID ? task : nil
        }
        let cancelledTasks = nativeMiMoHostConsumers[modelID].map { Array($0.values) } ?? []
        if !nativeMiMoJoinedServingOwners.contains(transaction.id),
            !liveTasks.isEmpty || !cancelledTasks.isEmpty {
            await rememberNativeMiMoPending(modelID: modelID, transaction: transaction,
                                             extraConsumers: liveTasks + cancelledTasks,
                                             joiningServingOwner: transaction.id)
            return false
        }

        let leases = nativeMiMoConsumerLeases[modelID].map { Array($0.values) } ?? []
        let unjoinedLeases = leases.filter {
            nativeMiMoJoinedLeaseRevisions[transaction.id]?[$0.id] != $0.snapshot().revision
        }
        if !unjoinedLeases.isEmpty {
            await rememberNativeMiMoPending(modelID: modelID, transaction: transaction,
                                             localConsumers: unjoinedLeases)
            return false
        }

        // The actual bundle/container remain strongly registered in the core.
        // Drop OUR redundant payload aliases before its final release/C step,
        // while keeping exact sizing metadata and the unloading tombstone. A
        // pending core result still retains every real native owner and charge.
        if let sizing = modelSlots[modelID]?.sizing ?? nativeMiMoCandidates[modelID]?.sizing {
            nativeMiMoRetiringSizing[modelID] = sizing
        }
        if modelSlots[modelID].flatMap({ Self.nativeMiMoLoad(in: $0.modelContainer) }) === load {
            modelSlots.removeValue(forKey: modelID)
        }
        nativeMiMoCandidates.removeValue(forKey: modelID)
        let result = await transaction.retire()
        guard case .retired = result else {
            await rememberNativeMiMoPending(modelID: modelID, transaction: transaction,
                                             watchConsumers: !nativeMiMoRegistry.hasRetainedFault)
            return false
        }
        // Drop only this exact slot/candidate after actual proof and host joins.
        // The core owns bundle release; do not call releaseAssistant again here.
        if modelSlots[modelID].flatMap({ Self.nativeMiMoLoad(in: $0.modelContainer) }) === load {
            modelSlots.removeValue(forKey: modelID)
        }
        nativeMiMoCandidates.removeValue(forKey: modelID)
        if let bridge, await engineV2Runtime.bridge(forModel: modelID) === bridge {
            await engineV2Runtime.unregister(modelId: modelID)
        }
        nativeMiMoLoads.removeValue(forKey: modelID)
        nativeMiMoRetiringSizing.removeValue(forKey: modelID)
        nativeMiMoPendingRetirements.removeValue(forKey: modelID)
        nativeMiMoRetirementReady.remove(modelID)
        nativeMiMoRetirementTasks.removeValue(forKey: modelID)
        nativeMiMoHostConsumers.removeValue(forKey: modelID)
        nativeMiMoJoinedServingOwners.remove(transaction.id)
        nativeMiMoJoinedBridgeProgress.removeValue(forKey: transaction.id)
        nativeMiMoShutdownIdentities.removeValue(forKey: transaction.id)
        for leaseID in nativeMiMoConsumerLeases[modelID].map({ Array($0.keys) }) ?? [] {
            nativeMiMoClosedConsumerLeaseIDs.remove(leaseID)
        }
        nativeMiMoConsumerLeases.removeValue(forKey: modelID)
        nativeMiMoJoinedLeaseRevisions.removeValue(forKey: transaction.id)
        modelsUnloading.remove(modelID)
        modelsLoading.remove(modelID)
        for waiter in unloadingWaiters.removeValue(forKey: modelID) ?? [] { waiter.resume() }
        syncWarmModelState()
        if !isShuttingDown { persistLoadedModelSet() }
        // Caller may still own the reslice gate while unwinding a failed build.
        // No cache/grant mutation is allowed while another closing owner remains.
        if nativeMiMoAllowsReclamation() {
            if hadNativePayload { clearCacheAfterConfirmedNativeOwnership() }
            await refreshActivationReserve()
            if nativeMiMoResliceOwners.contains(transaction.id) { await resliceGrowSurvivorsLocked() }
            else { await resliceGrowSurvivors() }
        }
        return true
    }

    private func nativeMiMoRetirementProgress(_ transaction: MiMoV26NativeLoadTransaction) async -> NativeMiMoRetirementProgress {
        let value = transaction.snapshot()
        var counts: [Int] = []
        if let bridge = transaction.registeredBridgeForRetirement() {
            counts = await bridge.nativeRetirementTaskSnapshot().progress
        }
        for (modelID, load) in nativeMiMoLoads where load.transaction === transaction {
            counts.append(nativeMiMoHostConsumers[modelID]?.count ?? 0)
            for lease in (nativeMiMoConsumerLeases[modelID] ?? [:]).values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                let snapshot = lease.snapshot()
                counts.append(Int(clamping: snapshot.revision))
                counts.append(snapshot.hasOutstandingHandoff ? 1 : 0)
            }
        }
        return .init(phase: value.phase.rawValue, operations: value.activeOperations,
                     constructionEpoch: value.constructionEpoch, constructionFailed: value.constructionFailed,
                     hostOwners: counts)
    }

    private func rememberNativeMiMoPending(modelID: String, transaction: MiMoV26NativeLoadTransaction,
                                           watchConsumers: Bool = true,
                                           extraConsumers: [Task<Void, Never>] = [],
                                           joiningServingOwner: UUID? = nil,
                                           localConsumers: [NativeLocalConsumerLease] = []) async {
        nativeMiMoPendingRetirements[modelID] = await nativeMiMoRetirementProgress(transaction)
        guard watchConsumers, nativeMiMoRetirementTasks[modelID] == nil,
            let bridge = transaction.registeredBridgeForRetirement() else { return }
        let snapshot = await bridge.nativeRetirementTaskSnapshot()
        // Generic pending can precede SDK completion (another drain may be
        // in progress). Only the actual validated SDK proof authorizes waiting
        // on tasks whose settlement itself depends on native retirement.
        guard let receipt = snapshot.sdkQuiescence,
            nativeMiMoShutdownIdentities[transaction.id]?.matches(receipt) == true else { return }
        let bridgeTasks = nativeMiMoJoinedBridgeProgress[transaction.id] == snapshot.progress ? [] : snapshot.tasks
        let tasks = bridgeTasks + extraConsumers
        guard !tasks.isEmpty || !localConsumers.isEmpty else { return }
        nativeMiMoRetirementTasks[modelID] = Task { [weak self] in
            for task in tasks { await task.value }
            for lease in localConsumers { await lease.joinFromOutside() }
            await self?.nativeMiMoConsumersMadeProgress(modelID, transactionID: transaction.id,
                joinedBridgeProgress: snapshot.progress, joinedServingOwner: joiningServingOwner,
                joinedLeases: Dictionary(uniqueKeysWithValues: localConsumers.map { ($0.id, $0.snapshot().revision) }))
        }
    }

    private func nativeMiMoConsumersMadeProgress(_ modelID: String, transactionID: UUID,
                                                 joinedBridgeProgress: [Int], joinedServingOwner: UUID?,
                                                 joinedLeases: [UUID: UInt64]) {
        guard nativeMiMoLoads[modelID]?.transaction?.id == transactionID else { return }
        nativeMiMoJoinedBridgeProgress[transactionID] = joinedBridgeProgress
        if joinedServingOwner == transactionID { nativeMiMoJoinedServingOwners.insert(transactionID) }
        nativeMiMoJoinedLeaseRevisions[transactionID, default: [:]].merge(joinedLeases) { _, new in new }
        nativeMiMoRetirementReady.insert(modelID)
        nativeMiMoRetirementTasks.removeValue(forKey: modelID)
    }

    func retryPendingNativeMiMoRetirements() async {
        for modelID in Array(nativeMiMoPendingRetirements.keys) {
            guard !nativeMiMoRetiring.contains(modelID), let transaction = nativeMiMoLoads[modelID]?.transaction else { continue }
            let current = await nativeMiMoRetirementProgress(transaction)
            guard nativeMiMoRetirementReady.remove(modelID) != nil
                || current != nativeMiMoPendingRetirements[modelID] else { continue }
            _ = await retireNativeMiMoOwner(modelID: modelID)
        }
    }
}
