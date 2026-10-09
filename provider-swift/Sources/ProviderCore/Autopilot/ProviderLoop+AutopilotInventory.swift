import Foundation

extension ProviderLoop {
    func autopilotModelInfo(_ id: String) -> ModelInfo? {
        advertisedModels[id] ?? autopilotInventoryModels[id]
    }

    /// Revocation only removes loadability. Actual resident ownership remains
    /// in the capacity snapshot and memory reserve until normal cleanup.
    func withdrawInactiveAutopilotModels() {
        guard !modelAutopilotEnabled else { return }
        for id in Array(advertisedModels.keys)
        where autopilotInventoryModels[id] != nil && !ordinaryServingModelIDs.contains(id)
            && autopilotCommand?.loadModelId != id {
            advertisedModels.removeValue(forKey: id)
        }
    }

    /// A new lease may resume already resident models. These IDs already belong
    /// to the reserve basis; cold candidates require an explicit owned command.
    func restoreAutopilotResidentModels() {
        guard modelAutopilotEnabled else { return }
        for id in modelSlots.keys where autopilotSettings.allows(id) && advertisedModels[id] == nil {
            if let model = autopilotInventoryModels[id], failedSelfTestHashes[id] == nil,
                !retiringModels.contains(id) { advertisedModels[id] = model }
        }
    }

    /// True when the target cannot be published after its victims retire:
    /// not in the inventory, no weight hash, a recorded failed self-test, or
    /// mid-retirement. Checked before any victim is unloaded.
    func autopilotTargetUnavailable(_ target: String) -> Bool {
        guard let model = autopilotInventoryModels[target], model.weightHash?.isEmpty == false else { return true }
        return failedSelfTestHashes[target] != nil || retiringModels.contains(target)
    }

    func autopilotTargetReserve(_ target: String) -> UInt64 {
        UnifiedMemoryCap.resolvedActivationReserveBytes(
            modelIDs: Array(advertisedModels.keys) + Array(modelSlots.keys)
                + Array(modelsLoading) + [target])
    }

    /// Prove that the target's floor leaves all non-victims serviceable before
    /// the first destructive step. The owned command excludes competing loads.
    func preflightAutopilotTarget(_ command: ModelAutopilotCommand) async throws {
        guard let target = command.loadModelId, advertisedModels[target] == nil else { return }
        await acquireResliceGate()
        defer { releaseResliceGate() }
        try checkAutopilotLoadOwnership(command.commandId)
        guard await reserveRaiseKeepsSurvivorsServiceable(
            reserveBytes: autopilotTargetReserve(target),
            excludingModelIDs: Set(command.unloadModelIds)) else {
            throw InferenceError.modelLoadFailed("autopilot_activation_reserve")
        }
        try checkAutopilotLoadOwnership(command.commandId)
    }

    /// Publish only the accepted command's target, after its victims retire.
    /// Match ordinary verified publication: own the reslice gate, check live
    /// survivors, pin the reserve across suspension, raise, then advertise.
    func prepareAutopilotTarget(_ command: ModelAutopilotCommand) async throws {
        guard let target = command.loadModelId, advertisedModels[target] == nil else { return }
        guard !autopilotTargetUnavailable(target), let model = autopilotInventoryModels[target] else {
            throw InferenceError.modelLoadFailed("model_not_cached")
        }
        await acquireResliceGate()
        defer { releaseResliceGate() }
        try checkAutopilotLoadOwnership(command.commandId)
        let reserve = autopilotTargetReserve(target)
        guard modelsLoading.isEmpty,
            await reserveRaiseKeepsSurvivorsServiceable(reserveBytes: reserve) else {
            throw InferenceError.modelLoadFailed("autopilot_activation_reserve")
        }
        try checkAutopilotLoadOwnership(command.commandId)
        pendingAdvertise.insert(target)
        await pushActivationReserve(reserve)
        do {
            try checkAutopilotLoadOwnership(command.commandId)
            guard !retiringModels.contains(target), failedSelfTestHashes[target] == nil,
                autopilotInventoryModels[target] == model else {
                throw InferenceError.modelLoadFailed("model_inventory_changed")
            }
            advertisedModels[target] = model
            pendingAdvertise.remove(target)
            await refreshActivationReserve()
            await resliceGrowSurvivorsLocked()
        } catch {
            pendingAdvertise.remove(target)
            await refreshActivationReserve()
            throw error
        }
    }
}
