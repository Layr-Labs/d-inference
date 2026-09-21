import Foundation

/// Shared manifest identity checks, download jobs and verified publication.
/// Foreground download and background prefetch keep their own scheduling and
/// progress behavior while using the same on-disk correctness boundary.
extension ModelDownloader {
    static func validate(manifest: ModelManifest, for model: CatalogModel) throws {
        guard manifest.modelID == model.id else {
            throw ModelCatalogError.downloadFailed("manifest model_id \(manifest.modelID) does not match catalog id \(model.id)")
        }
        guard manifest.files.count == manifest.fileCount else {
            throw ModelCatalogError.downloadFailed("manifest file_count \(manifest.fileCount) does not match files array")
        }
        guard !manifest.files.isEmpty else {
            throw ModelCatalogError.downloadFailed("manifest contains no files")
        }
        if let aggregate = model.aggregateSHA256, aggregate != manifest.aggregateSHA256 {
            throw ModelCatalogError.downloadFailed("catalog aggregate hash does not match manifest")
        }
        if let prefix = model.r2Prefix, prefix != manifest.r2Prefix {
            throw ModelCatalogError.downloadFailed("catalog r2_prefix does not match manifest")
        }
    }

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
    /// (`snapshots/local` + `refs/main`) so `ModelScanner` discovers it. Shared by
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
        cacheDir: URL
    ) throws {
        let aggregate = WeightHasher.hashFilesWithRelativeKey(jobs.map { (file: $0.destination, sortKey: $0.file.path) })
        guard aggregate == manifest.aggregateSHA256 else {
            try? FileManager.default.removeItem(at: stagingDir)
            throw ModelCatalogError.downloadFailed("aggregate hash mismatch for \(model.id)")
        }
        try Self.publishStagedSnapshot(stagingDir, to: cacheDir)
        try writeMainRef(for: model.id)
        // Staging was consumed by publishStagedSnapshot; best-effort husk cleanup.
        try? FileManager.default.removeItem(at: stagingDir)
    }
}
