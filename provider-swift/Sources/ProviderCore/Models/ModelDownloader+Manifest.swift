import Foundation

/// Shared manifest download jobs and verified publication.
/// Foreground download and background prefetch keep their own scheduling and
/// progress behavior while using the same on-disk correctness boundary.
extension ModelDownloader {
    func manifestJobs(
        _ manifest: ModelManifest, stagingDir: URL
    ) throws -> [(file: ManifestFile, destination: URL, url: String)] {
        try manifest.files.map { file -> (file: ManifestFile, destination: URL, url: String) in
            let relativePath = try Self.validatedManifestRelativePath(file.path)
            return (
                file: file,
                destination: stagingDir.appendingPathComponent(relativePath, isDirectory: false),
                url: "\(r2CDNURL)/\(Self.escapeR2Path(manifest.r2Prefix))/\(Self.escapeR2Path(relativePath))"
            )
        }
    }

    /// Verify the aggregate hash over the staged files, then publish the snapshot
    /// (immutable revision + optional `refs/main`) so `ModelScanner` discovers it. Shared by
    /// the normal completion path and the finish-on-restart short-circuit.
    ///
    /// On an aggregate mismatch over internally-valid files (a poisoned manifest:
    /// every per-file SHA passed but the claimed aggregate is wrong) staging is
    /// cleared so a corrected manifest re-downloads cleanly — otherwise skip-valid
    /// would re-fail the aggregate forever. Transient per-file/network failures
    /// throw earlier and deliberately KEEP staging so the next attempt resumes.
    func finalizeStagedManifest(
        model: CatalogModel,
        manifest: ModelManifest,
        jobs: [(file: ManifestFile, destination: URL, url: String)],
        stagingDir: URL,
        cacheDir: URL,
        activate: Bool = true
    ) throws {
        let aggregate = WeightHasher.hashFilesWithRelativeKey(jobs.map { (file: $0.destination, sortKey: $0.file.path) })
        guard aggregate == manifest.aggregateSHA256 else {
            try? FileManager.default.removeItem(at: stagingDir)
            throw ModelCatalogError.downloadFailed("aggregate hash mismatch for \(model.id)")
        }
        try Self.publishRevision(
            stagingDir: stagingDir, directory: cacheDir, manifest: manifest, activationRequested: activate)
        if activate { try Self.activateRevision(modelID: model.id, directory: cacheDir) }
        // Staging was consumed by publication; best-effort husk cleanup.
        try? FileManager.default.removeItem(at: stagingDir)
    }
}
