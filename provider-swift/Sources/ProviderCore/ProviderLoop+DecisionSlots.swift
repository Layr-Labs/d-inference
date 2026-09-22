import Foundation
import MLX
import MLXDecisions
import ProviderCoreFoundation

extension ProviderLoop {
    struct DecisionSlot: Sendable {
        let runtime: LayaRuntime
        let weightsBytes: Int
        let loadTimeMs: Int64
        var lastInferenceAt: ContinuousClock.Instant
    }

    struct ResidentModelFacts {
        let weightsBytes: Int
        let lastInferenceAt: ContinuousClock.Instant
    }

    var residentModelIDs: Set<String> { Set(modelSlots.keys).union(decisionSlots.keys) }

    func isModelResident(_ modelID: String) -> Bool {
        modelSlots[modelID] != nil || decisionSlots[modelID] != nil
    }

    var residentModelFacts: [String: ResidentModelFacts] {
        var result = modelSlots.mapValues {
            ResidentModelFacts(weightsBytes: $0.sizing.weightsBytes, lastInferenceAt: $0.lastInferenceAt)
        }
        for (id, slot) in decisionSlots {
            result[id] = ResidentModelFacts(weightsBytes: slot.weightsBytes, lastInferenceAt: slot.lastInferenceAt)
        }
        return result
    }

    /// Until a mixed serving-set activation envelope is measured, decisions and
    /// autoregressive slots never coexist. Busy or retained targets are never evicted.
    func decisionExclusivityAvailable(modelId: String) -> Bool {
        let isDecision = advertisedModels[modelId]?.systemOne == true || decisionSlots[modelId] != nil
        if isDecision && mtpStagingReservations.hasRetainedTargets { return false }
        let incompatible = isDecision ? residentModelIDs.subtracting([modelId]) : Set(decisionSlots.keys)
        return incompatible.allSatisfy {
            !requestToModel.values.contains($0) && !decisionRequestOwners.values.contains($0)
                && !hasLocalReservation($0) && !modelsUnloading.contains($0)
                && !isMTPUpgradeTargetRetained($0)
        }
    }

    /// Called inside the existing process-wide load gate.
    func prepareDecisionExclusivity(modelId: String, isDecision: Bool, allowEviction: Bool) async throws {
        guard !isDecision || !mtpStagingReservations.hasRetainedTargets else {
            throw InferenceError.modelLoadFailed("Native decision slot cannot overlap a retained MTP target")
        }
        let incompatible = isDecision ? residentModelIDs.subtracting([modelId]) : Set(decisionSlots.keys)
        guard !incompatible.isEmpty else { return }
        guard allowEviction, decisionExclusivityAvailable(modelId: modelId) else {
            throw InferenceError.modelLoadFailed("Native decision slot requires idle exclusive model residency")
        }
        let available = await availableMemoryGb()
        let reclaimable = incompatible.reduce(0.0) { $0 + Double(residentModelFacts[$1]?.weightsBytes ?? 0) / 1_073_741_824 }
            + Double(max(0, MLX.Memory.cacheMemory)) / 1_073_741_824
        let required = ModelLoadAdmission.requiredToLoadGb(
            weightsGb: advertisedModels[modelId]?.estimatedMemoryGb ?? 0, headroomGb: loadHeadroomGb)
        guard ModelLoadAdmission.evictionCanReach(availableGb: available, reclaimableGb: reclaimable, requiredGb: required),
            decisionExclusivityAvailable(modelId: modelId) else {
            throw InferenceError.modelLoadFailed("Insufficient memory for exclusive native decision slot")
        }
        for id in incompatible.sorted() {
            guard await unloadModel(id, forEviction: true) else {
                throw InferenceError.modelLoadFailed("Model slot became busy during native decision admission")
            }
        }
    }

    func installDecisionSlot(
        modelId: String, directory: URL, modelInfo: ModelInfo,
        preLoadHash: WeightHashSnapshot, lease: PendingModelLoadLease,
        startedAt: ContinuousClock.Instant
    ) async throws {
        guard LayaModelLayout.isSupported(at: directory) else {
            throw InferenceError.invalidModelDirectory("Unsupported native decision checkpoint")
        }
        _ = try GPUEnforcement.requireMetal()
        MLXMemoryGuard.configureOnce()
        let runtime = try await LayaRuntime.load(directory: directory)
        do {
            try Task.checkCancellation()
            if isShuttingDown { throw CancellationError() }
            try throwIfRetiring(modelId)
            let after = try await captureWeightHash(modelId: modelId, modelPath: directory, requireFreshCryptographicHash: true)
            guard let hash = preLoadHash.hash, after.hash == hash else {
                throw InferenceError.modelLoadFailed("Native decision checkpoint changed while loading")
            }
            guard await kvBudget.reducePendingLoad(lease, remainingWeightBytes: 0) else {
                throw InferenceError.modelLoadFailed("Native decision load ownership changed")
            }
            MLX.Memory.clearCache()
            guard KVHeadroomProbe.hasServeableKVHeadroom(activationReserveBytes: resolvedActivationReserveBytes) else {
                throw InferenceError.modelLoadFailed("Insufficient measured headroom for native decision slot")
            }
            await publishWeightHash(modelId: modelId, snapshot: after)
            try Task.checkCancellation()
            if isShuttingDown { throw CancellationError() }
            try throwIfRetiring(modelId)
            let elapsed = ContinuousClock.now - startedAt
            decisionSlots[modelId] = DecisionSlot(
                runtime: runtime, weightsBytes: Int(min(modelInfo.sizeBytes, UInt64(Int.max))),
                loadTimeMs: Int64(max(0, elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)),
                lastInferenceAt: .now)
        } catch {
            await runtime.shutdown()
            throw error
        }
    }

    func unloadDecisionSlot(_ modelId: String, forEviction: Bool) async -> Bool {
        guard !modelsUnloading.contains(modelId), let runtime = decisionSlots[modelId]?.runtime else { return false }
        if forEviction && (requestToModel.values.contains(modelId) || decisionRequestOwners.values.contains(modelId)) { return false }
        modelsUnloading.insert(modelId)
        // Actor barrier waits for any synchronous GPU evaluation, then releases
        // the weights even when an already-cancelled task still retains runtime.
        await runtime.shutdown()
        decisionSlots.removeValue(forKey: modelId)
        modelsUnloading.remove(modelId)
        MLX.Memory.clearCache()
        await refreshActivationReserve()
        for waiter in unloadingWaiters.removeValue(forKey: modelId) ?? [] { waiter.resume() }
        syncWarmModelState()
        if !isShuttingDown { persistLoadedModelSet() }
        await updateAggregateCapacity()
        await retryReserveDeferredPrefetches()
        return true
    }

    /// The 32,768-token figures are conservative request reservations, not
    /// observed work. Native decisions retain no KV and do not expose live token
    /// activity/TPS, so the required legacy active_tokens field remains zero.
    /// Actual input usage is measured by the runtime only on completion.
    func decisionCapacitySlots() -> [BackendSlotCapacity] {
        decisionSlots.map { id, slot in
            let busy = decisionRequestOwners.values.contains(id)
            return BackendSlotCapacity(
                model: id, state: modelsUnloading.contains(id) ? "reloading" : (busy ? "running" : "idle"),
                numRunning: busy ? 1 : 0, numWaiting: 0,
                activeTokens: 0, maxTokensPotential: busy ? 32_768 : 0,
                maxConcurrency: 1, activeTokenBudgetUsed: busy ? 32_768 : 0,
                activeTokenBudgetMax: 32_768, modelLoadTimeMs: slot.loadTimeMs)
        }
    }
}
