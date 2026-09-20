import Foundation

extension ProviderLoop {
    /// Restore durable selection before advertising or loading the old revision.
    /// A disk/engine failure leaves admission fenced; the reconciler can retry
    /// without claiming that a rollback succeeded when it did not.
    func restoreModelRevision(_ staged: StagedModelRevision, oldDirectory: URL?,
                              oldInfo: ModelInfo?, oldHash: String?, wasWarm: Bool) async -> Bool {
        let id = staged.entry.desiredBuild
        do {
            if modelSlots[id] != nil { _ = await unloadModel(id, revisionUpdate: true) }
            if let oldDirectory {
                // A load failure normally leaves the old ref untouched. Do
                // not require a disk write merely to retain that valid ref.
                if ModelScanner.resolveLocalPath(modelID: id) != oldDirectory {
                    try ModelDownloader.activateRevision(modelID: id, directory: oldDirectory)
                }
            } else {
                guard oldInfo == nil else {
                    throw ModelCatalogError.downloadFailed("previous advertised snapshot selection is unavailable")
                }
                let ref = ModelDownloader.cacheModelDirectory(for: id).appendingPathComponent("refs/main")
                if FileManager.default.fileExists(atPath: ref.path) { try FileManager.default.removeItem(at: ref) }
            }
            advertisedModels[id] = oldInfo
            liveModelHashes[id] = oldHash
            modelHashes[id] = oldHash
            modelHashFingerprints.removeValue(forKey: id)
            syncWarmModelState()
            await coordinatorClient?.updateModelWeightHashes(liveModelHashes)
            if let oldInfo {
                await coordinatorClient?.advertiseModel(oldInfo)
                outboundSend?.send(.modelsUpdate(models: [oldInfo]))
            } else {
                await coordinatorClient?.unadvertiseModel(id)
                await coordinatorClient?.forceReconnect()
            }
            if wasWarm, !isShuttingDown {
                try await ensureModelLoaded(modelId: id, allowEviction: false, revisionUpdate: true)
            }
            await refreshActivationReserve()
            await resliceGrowSurvivors()
            await updateAggregateCapacity()
            logger.warning("model revision activation failed; restored previous selection: model=\(id)")
            return true
        } catch {
            logger.error("model revision recovery failed; admission remains closed: model=\(id) error=\(error)")
            return false
        }
    }
}
