import Foundation

extension ModelDownloader {
    /// Explicit setup download plan. Byte-resume credit uses the same verified
    /// staging files and .part accounting as the downloader itself.
    public func selectedDownloadPlan(models: [CatalogModel]) async throws -> (remainingBytes: Int64, availableBytes: Int64?) {
        var remaining: Int64 = 0
        var directory: URL?
        for model in models {
            let snapshots = Self.cacheSnapshotDirectory(for: model.id).deletingLastPathComponent()
            try Self.prepareModelCacheDirectory(at: snapshots.deletingLastPathComponent())
            try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
            directory = snapshots
            let bytes: Int64
            if model.r2Prefix != nil, model.aggregateSHA256 != nil {
                let manifest = try await resolveManifest(model: model)
                try Self.validateArtifactManifest(manifest, model: model)
                let revision = try Self.revisionSnapshotDirectory(manifest: manifest)
                if Self.verifiedRevisionExists(at: revision, manifest: manifest) {
                    bytes = 0
                } else {
                    let staging = snapshots.appendingPathComponent(Self.localStagingDirName(r2Prefix: manifest.r2Prefix))
                    let jobs = try manifestJobs(manifest, stagingDir: staging)
                    bytes = Self.remainingBytesToFetch(sizes: jobs.map(\.file.sizeBytes),
                        alreadyValid: jobs.map { Self.fileMatches($0.destination, size: $0.file.sizeBytes, sha256: $0.file.sha256) },
                        partBytes: jobs.map { fileSize($0.destination.appendingPathExtension("part")) })
                }
            } else {
                guard model.sizeGb.isFinite, model.sizeGb > 0, model.sizeGb < 4096 else {
                    throw ModelCatalogError.downloadFailed("Unknown download size for \(model.id)")
                }
                bytes = model.totalSizeBytes ?? Int64(model.sizeGb * 1e9)
            }
            let sum = remaining.addingReportingOverflow(max(0,bytes))
            guard !sum.overflow else { throw ModelCatalogError.downloadFailed("Download size overflow") }
            remaining = sum.partialValue
        }
        guard let directory else { return (0,nil) }
        try Self.ensureAvailableCapacity(at: directory, requiredBytes: remaining)
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return (remaining,values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init))
    }

    /// Enrollment is committed only after every selected build matches its
    /// catalog identity. Merely discovering a directory does not verify it.
    public func verifySelectedModel(_ model: CatalogModel) async throws {
        let manifest: ModelManifest?
        if model.r2Prefix != nil, model.aggregateSHA256 != nil {
            let resolved = try await resolveManifest(model: model)
            try Self.validateArtifactManifest(resolved, model: model)
            manifest = resolved
        } else {
            manifest = nil
        }
        // An existing daemon may retain this lease while its prepared update
        // waits for rollout jitter. Do not silently block a foreground start.
        try Task.checkCancellation()
        let lease = try ModelArtifactWriteLease.acquireIfAvailable(modelID: model.id, operation: "verification")
        defer { lease.release() }
        guard let path = ModelScanner.resolveLocalPath(modelID: model.id) else {
            throw ModelCatalogError.downloadFailed("Selected model is missing: \(model.id)")
        }
        if let manifest {
            let revision = try Self.revisionSnapshotDirectory(manifest: manifest)
            let managed = path.lastPathComponent.hasPrefix(".revision-")
                && path.deletingLastPathComponent().resolvingSymlinksInPath()
                    == revision.deletingLastPathComponent().resolvingSymlinksInPath()
            guard !managed || path.resolvingSymlinksInPath() == revision.resolvingSymlinksInPath() else {
                throw ModelCatalogError.downloadFailed("Selected revision is not current: \(model.id); run darkbloom models download \(model.id)")
            }
            let verified = managed
                ? try Self.verifyRevisionAndRepairReceipt(at: path, manifest: manifest)
                : Self.verifiedRevisionExists(at: path, manifest: manifest)
            guard verified else {
                throw ModelCatalogError.downloadFailed("Selected build verification failed: \(model.id); run darkbloom models download \(model.id)")
            }
        } else {
            guard let expected = model.weightHash, !expected.isEmpty,
                  WeightHasher.computeHash(snapshotDir: path, modelID: model.id) == expected else {
                throw ModelCatalogError.downloadFailed("Selected build has no matching verified weight hash: \(model.id)")
            }
        }
    }
}
