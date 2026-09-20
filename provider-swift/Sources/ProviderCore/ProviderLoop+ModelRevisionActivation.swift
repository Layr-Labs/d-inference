import Foundation

struct StagedModelRevision: Sendable {
    let entry: CoordinatorMessage.DesiredModelEntry
    let directory: URL
    let info: ModelInfo
    let lease: ModelArtifactWriteLease
    let totalSizeBytes: Int64
    let owner = UUID()
}

extension ProviderLoop {
    func beginModelRevisionDrain(_ staged: StagedModelRevision) async throws {
        let id = staged.entry.desiredBuild
        try Task.checkCancellation()
        guard revisionIsDesired(staged.entry), prefetchPublicationCounts[id] == nil,
            !isMTPUpgradeTargetRetained(id), !isRefusedByRetirement(id)
        else { throw CancellationError() }
        if let failedOwner = failedModelRevisionRestores.removeValue(forKey: id) {
            mtpAdmissionDrains.end(id, owner: failedOwner)
        }
        guard mtpAdmissionDrains.begin(id, owner: staged.owner) else { throw CancellationError() }
        revisionUpdatesInProgress.insert(id)
        state.setModelAdmissionDraining(id, true)
        await updateAggregateCapacity()
        await coordinatorClient?.sendEventHeartbeat()
    }

    func finishModelRevisionDrain(_ staged: StagedModelRevision) async {
        let id = staged.entry.desiredBuild
        if failedModelRevisionRestores[id] != staged.owner, mtpAdmissionDrains.end(id, owner: staged.owner) {
            revisionUpdatesInProgress.remove(id)
            state.setModelAdmissionDraining(id, false)
            await updateAggregateCapacity()
            await coordinatorClient?.sendEventHeartbeat()
        }
        staged.lease.release()
    }

    func commitModelRevisionIfIdle(_ staged: StagedModelRevision) async throws -> Bool {
        let id = staged.entry.desiredBuild
        try Task.checkCancellation()
        guard revisionIsDesired(staged.entry), !isRefusedByRetirement(id) else { throw CancellationError() }
        guard !isLoadingAny, !modelsUnloading.contains(id), !isMTPUpgradeTargetRetained(id),
            !mtpUpgradeTransitions.contains(id), !requestToModel.values.contains(id), !hasLocalReservation(id)
        else { return false }
        if let bridge = modelSlots[id]?.engineV2 {
            let capacity = await bridge.capacitySnapshot()
            guard capacity.activeRequests == 0, capacity.waitingRequests == 0, capacity.kvBytesReserved == 0 else { return false }
        }
        // Recheck after the bridge hop. Admission is closed, but an accepted
        // request or preload may have been finishing its load meanwhile.
        guard revisionIsDesired(staged.entry), !isLoadingAny, !modelsUnloading.contains(id),
            !requestToModel.values.contains(id), !hasLocalReservation(id), !isMTPUpgradeTargetRetained(id)
        else { return false }
        let oldDirectory = ModelScanner.resolveLocalPath(modelID: id)
        let oldInfo = advertisedModels[id]
        let oldHash = liveModelHashes[id]
        let wasWarm = modelSlots[id] != nil
        modelRevisionActivationID = id
        mtpUpgradeTransitions.insert(id)
        defer {
            modelRevisionActivationID = nil
            finishMTPUpgradeTransition(id)
            releaseLoadGateWaiters()
        }
        do {
            if wasWarm { _ = await unloadModel(id, revisionUpdate: true) }
            try Task.checkCancellation()
            guard revisionIsDesired(staged.entry) else { throw CancellationError() }
            if wasWarm {
                // Normal load admission, memory sizing and engine validation
                // apply; this never requires both full targets in GPU memory.
                advertisedModels[id] = staged.info
                try await ensureModelLoaded(modelId: id, allowEviction: false, revisionUpdate: true, revisionDirectory: staged.directory)
                guard liveModelHashes[id] == staged.entry.aggregateSHA256 else {
                    throw ModelCatalogError.downloadFailed("loaded revision hash does not match the verified artifact")
                }
            }
            try Task.checkCancellation()
            guard revisionIsDesired(staged.entry) else { throw CancellationError() }
            // Persist selection only after a warm replacement has loaded. A
            // process crash during validation boots the previous snapshot.
            try ModelDownloader.activateRevision(modelID: id, directory: staged.directory)
            let published = await publishVerifiedPrefetch(modelId: id, expectedRevision: staged.entry,
                verifiedArtifact: (staged.info, staged.entry.aggregateSHA256!))
            try Task.checkCancellation()
            guard revisionIsDesired(staged.entry) else { throw CancellationError() }
            guard published, advertisedModels[id]?.weightHash == staged.entry.aggregateSHA256,
                modelHashes[id] == staged.entry.aggregateSHA256
            else { throw ModelCatalogError.downloadFailed("verified revision could not be advertised") }
            // No suspension between validating this attempt and consuming the
            // current alias lineage. A superseded attempt leaves it for retry.
            let previousBuild = desiredSwapDrop.removeValue(forKey: id)
            if let previousBuild, previousBuild != id { await dropAdvertisedBuild(previousBuild) }
            outboundSend?.send(.prefetchModelStatus(modelId: id, status: .verified,
                bytesDone: staged.totalSizeBytes, bytesTotal: staged.totalSizeBytes, error: nil))
            return true
        } catch {
            // Recovery is not cancelled with a superseded attempt.
            let restored = await Task {
                await restoreModelRevision(staged, oldDirectory: oldDirectory,
                    oldInfo: oldInfo, oldHash: oldHash, wasWarm: wasWarm)
            }.value
            if !restored { failedModelRevisionRestores[id] = staged.owner }
            throw error
        }
    }
}
