import Foundation

extension ProviderLoop {
    /// Local admission remains closed until the coordinator confirms the whole
    /// inventory on this connection. Persist before publishing so a crash after
    /// the receipt cannot restart with the old launchd selection.
    internal func commitModelSelection(_ selection: ProviderModelSwitchValidation.Result, drainID: String) async throws {
        let models = selection.models
        guard let client = coordinatorClient else { throw ModelSelectionFailure("Coordinator connection is unavailable.") }
        let previous = ProviderModelSwitchValidation.Result(
            models: advertisedModels.values.map { info in
                var model = info
                model.weightHash = liveModelHashes[info.id] ?? info.weightHash
                return model
            }.sorted { $0.id < $1.id },
            fingerprints: modelHashFingerprints)
        let previouslyPersistedSwitch = hasPersistedModelSwitch
        var persistedReplacement: ProviderModelSelection.Replacement?
        var mutationStarted = false
        do {
            try validateModelSwitchSelfTests(models)
            try await client.validateModelSelectionAfterDrain(models, drainID: drainID, timeout: .seconds(30))
            mutationStarted = true
            try await applyModelSelection(selection)
            await client.stageModelSelection(models)
            try checkModelSwitchOwnership()
            if let path = loopConfig.configPath {
                persistedReplacement = try ProviderModelSelection.stageReplacement(
                    models.map(\.id), configPath: path, fallbackConfig: loopConfig.config)
                hasPersistedModelSwitch = true
            }
            // Discard only pre-commit state. The coordinator forces a current
            // desired snapshot after this ack; preserve arrivals during the wait.
            discardObsoleteModelPrefetches()
            try await client.replaceModelsAfterDrain(models, drainID: drainID, timeout: .seconds(30))
        } catch {
            await client.stageModelSelection(advertisedModels.values.sorted { $0.id < $1.id })
            if let wire = error as? ModelSwitchError {
                switch wire {
                case .timedOut, .disconnected:
                    throw error
                default:
                    break
                }
            }
            guard servingDrain.owner == .modelSwitch, !isShuttingDown, !Task.isCancelled else { throw error }
            do {
                if mutationStarted { try await applyModelSelection(previous) }
                await client.stageModelSelection(previous.models)
                if let persistedReplacement {
                    try ProviderModelSelection.restore(persistedReplacement)
                    hasPersistedModelSwitch = previouslyPersistedSwitch
                }
                discardObsoleteModelPrefetches()
                try await client.replaceModelsAfterDrain(previous.models, drainID: drainID, timeout: .seconds(30))
                await resumeAfterModelSwitch()
            } catch let rollbackError {
                throw ModelSelectionFailure("Switch failed: \(error). Restoring the previous selection is unconfirmed: \(rollbackError).")
            }
            throw ModelSelectionFailure("Switch refused; previous selection restored: \(error)")
        }
    }

    /// Uses the normal unload/resource retirement and KV re-slice paths. The
    /// advertised set changes only after resident survivors pass the same floor
    /// check used by prefetch. New slots still use ensureModelLoaded on demand.
    internal func applyModelSelection(_ selection: ProviderModelSwitchValidation.Result) async throws {
        let models = selection.models
        try checkModelSwitchOwnership()
        try validateModelSwitchSelfTests(models)
        guard !isLoadingAny, modelsLoading.isEmpty else {
            throw ModelSelectionFailure("A model load is still in progress.")
        }
        isLoadingAny = true
        defer { isLoadingAny = false; releaseLoadGateWaiters() }
        let next = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        let retiring = Set(modelSlots.keys.filter {
            next[$0] == nil || next[$0]?.weightHash != liveModelHashes[$0]
        })
        let reserve = UnifiedMemoryCap.resolvedActivationReserveBytes(modelIDs: models.map(\.id))
        await acquireResliceGate()
        let serviceable = await reserveRaiseKeepsSurvivorsServiceable(
            reserveBytes: reserve, excludingModelIDs: retiring)
        releaseResliceGate()
        try checkModelSwitchOwnership()
        guard serviceable else {
            throw ModelSelectionFailure("The selected models' activation reserve would leave a resident model without enough KV memory. Choose a smaller serving set.")
        }
        // Remote inventory and projected survivor budgets passed before the
        // first destructive step. A same-ID changed hash retires old bytes too.
        for id in retiring {
            _ = await unloadModel(id)
            if modelsUnloading.contains(id) { await waitForModelUnload(id) }
            try checkModelSwitchOwnership()
        }
        await acquireResliceGate()
        defer { releaseResliceGate() }
        try checkModelSwitchOwnership()
        advertisedModels = next
        modelHashes = Dictionary(uniqueKeysWithValues: models.compactMap { model in
            model.weightHash.map { (model.id, $0) }
        })
        liveModelHashes = modelHashes
        modelHashFingerprints = selection.fingerprints
        if let error = lastModelLoadError, next[error.model] == nil { lastModelLoadError = nil }
        syncWarmModelState()
        await refreshActivationReserve()
        await resliceGrowSurvivorsLocked()
        await updateAggregateCapacity()
        persistLoadedModelSet()
    }

    internal func validateModelSwitchSelfTests(_ models: [ModelInfo]) throws {
        for model in models {
            if retiringModels.contains(model.id) {
                throw ModelSelectionFailure("Model '\(model.id)' is being retired after a failed self-test.")
            }
            if let failed = failedSelfTestHashes[model.id], failed.isEmpty || failed == model.weightHash {
                throw ModelSelectionFailure("Model '\(model.id)' is fenced after a failed self-test; choose another build.")
            }
        }
    }

    private func discardObsoleteModelPrefetches() {
        // Old desired snapshots refer to the pre-switch inventory. Clear before
        // sending the commit, never after its ack (a fresh push may be deferred).
        deferredDesiredModels = nil
        staleDesiredPrefetches.formUnion(desiredPrefetchTargets.subtracting(advertisedModels.keys))
        desiredPrefetchTargets.removeAll()
        desiredSwapDrop.removeAll()
        reserveDeferredPrefetches.removeAll()
        for task in desiredPrefetchRetryTasks.values { task.cancel() }
        desiredPrefetchRetryTasks.removeAll()
        desiredPrefetchRetryAttempts.removeAll()
        for task in deferredPrefetchWakeups.values { task.cancel() }
        deferredPrefetchWakeups.removeAll()
    }
}
