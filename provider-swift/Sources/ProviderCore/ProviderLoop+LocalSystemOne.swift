import Foundation
import MLXDecisions

extension ProviderLoop {
    /// One native request owns the slot through actual evaluation completion.
    /// HTTP cancellation propagates to the runtime's batch-boundary checks.
    func predictSystemOneForLocal(data: Data) async throws -> Data {
        let request = try SystemOneRequest(data: data)
        let modelId = request.model
        try throwIfRefusingNewLocalWork(modelId: modelId)
        guard advertisedModels[modelId]?.systemOne == true else {
            throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId)
        }
        guard decisionRequestOwners.isEmpty else {
            throw MultiModelBatchSchedulerEngineError.queueFull("Native decision slot is busy")
        }
        let owner = "local-systemone:" + UUID().uuidString
        decisionRequestOwners[owner] = modelId
        localReservations.reserve(modelId)
        powerAssertion.acquire()
        defer {
            decisionRequestOwners.removeValue(forKey: owner)
            localReservations.release(modelId)
            powerAssertion.release()
            decisionSlots[modelId]?.lastInferenceAt = .now
            syncWarmModelState()
            Task { await self.updateAggregateCapacity() }
        }
        do { try await ensureModelLoaded(modelId: modelId) }
        catch let failure as InferenceError {
            if Self.loadErrorStatusCode(for: failure) == 404 {
                throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId)
            }
            throw MultiModelBatchSchedulerEngineError.queueFull("Native decision model capacity unavailable")
        }
        try Task.checkCancellation()
        try throwIfRefusingNewLocalWork(modelId: modelId)
        guard let runtime = decisionSlots[modelId]?.runtime else {
            throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId)
        }
        guard KVHeadroomProbe.hasServeableKVHeadroom(activationReserveBytes: resolvedActivationReserveBytes) else {
            throw MultiModelBatchSchedulerEngineError.queueFull("Native decision activation headroom unavailable")
        }
        syncWarmModelState()
        await updateAggregateCapacity()
        return try await runtime.predict(request)
    }
}
