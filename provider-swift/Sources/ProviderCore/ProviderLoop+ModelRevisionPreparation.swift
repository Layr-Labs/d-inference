import Foundation

extension ProviderLoop {
    /// Prefetch releases its writer lease before catalog prewarming. A CLI
    /// removal or download can change both snapshots in that gap. Reacquire
    /// ownership and revalidate the replacement AND the rollback bytes before
    /// any admission drain or destructive engine unload begins.
    func protectPreparedModelRevision(
        _ entry: CoordinatorMessage.DesiredModelEntry, directory: URL, manifest: ModelManifest
    ) async throws -> StagedModelRevision? {
        let id = entry.desiredBuild
        let lease = try await ModelArtifactWriteLease.acquire(modelID: id)
        var transferredLease = false
        defer { if !transferredLease { lease.release() } }
        try Task.checkCancellation()
        guard revisionIsDesired(entry) else { return nil }
        guard manifest.modelID == id, manifest.version == entry.revision,
            manifest.aggregateSHA256 == entry.aggregateSHA256 else {
            throw ModelCatalogError.downloadFailed("prepared snapshot does not match the desired revision")
        }
        let selectionRevision = modelSelectionRevision
        let oldDirectory = ModelScanner.resolveLocalPath(modelID: id)
        let oldHash = liveModelHashes[id]
        let needsRollback = advertisedModels[id] != nil || modelSlots[id] != nil
        let info = try await Task.detached(priority: .utility) {
            guard try ModelDownloader.verifyRevisionAndRepairReceipt(at: directory, manifest: manifest) else {
                throw ModelCatalogError.downloadFailed("prepared revision changed before activation ownership was acquired")
            }
            if needsRollback {
                guard let oldDirectory, let oldHash, !oldHash.isEmpty,
                    WeightHasher.computeHash(snapshotDir: oldDirectory, modelID: id) == oldHash else {
                    throw ModelCatalogError.downloadFailed("previous revision is unavailable or changed; preserving the running model")
                }
            }
            guard var info = ModelScanner.parseModelInfo(snapshotDir: directory, modelName: id),
                info.templateRenderOK != false, EngineV2SupportedModels.isSupported(model: info) else {
                throw ModelCatalogError.downloadFailed("revision failed engine/template compatibility checks")
            }
            info.weightHash = manifest.aggregateSHA256
            return info
        }.value
        try Task.checkCancellation()
        guard revisionIsDesired(entry), modelSelectionRevision == selectionRevision else { return nil }
        // Hashing suspends the actor. Retirement or a foreground load may have
        // changed the live inventory even though filesystem writers were fenced.
        guard ModelScanner.resolveLocalPath(modelID: id) == oldDirectory,
            liveModelHashes[id] == oldHash,
            (advertisedModels[id] != nil || modelSlots[id] != nil) == needsRollback else {
            throw ModelCatalogError.downloadFailed("serving selection changed while preparing the revision")
        }
        transferredLease = true
        return StagedModelRevision(entry: entry, directory: directory, info: info, lease: lease,
            totalSizeBytes: manifest.totalSizeBytes)
    }
}
