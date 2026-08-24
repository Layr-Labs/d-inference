/// ModelDownloader resume-aware prefetch (background, no GPU load):
/// resolve manifest, resumable prefetch + verify, staging detection,
/// remaining-bytes accounting, and the disk-capacity pre-check.

import Foundation

extension ModelDownloader {
    // MARK: - Resume-aware prefetch (background, no GPU load)

    /// Resolve the manifest for a catalog model via the same paths `download`
    /// uses (coordinator registry first, CDN fallback). Exposed so the prefetch
    /// coordinator can size total bytes / short-circuit before starting.
    public func resolveManifest(model: CatalogModel) async throws -> ModelManifest {
        if let catalogClient {
            return try await catalogClient.fetchManifest(modelID: model.id)
        }
        return try await fetchManifestFromCDN(model: model)
    }

    /// Download + verify a manifest model on disk WITHOUT loading it into GPU,
    /// resuming an interrupted prefetch instead of restarting from zero.
    ///
    /// Resume strategy: a STABLE per-model staging directory (keyed by the
    /// manifest's `r2Prefix`, not a random UUID) survives an interrupted
    /// prefetch. On re-entry, any file already present in staging that matches
    /// its manifest size AND SHA-256 is skipped; only missing/corrupt files are
    /// re-fetched. Per-file SHA is verified as each file lands; the aggregate
    /// hash is verified before the snapshot is published. The published snapshot
    /// is the same `snapshots/local` layout `download` produces, so
    /// `ModelScanner` discovers it immediately.
    ///
    /// `onByteProgress(done, total)` reports cumulative verified-on-disk bytes
    /// against the manifest total (already-present files count as done up front).
    public func prefetch(
        model: CatalogModel,
        manifest: ModelManifest,
        onByteProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws {
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

        let cacheDir = Self.cacheSnapshotDirectory(for: model.id)
        let snapshotsDir = cacheDir.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)

        // STABLE staging dir keyed by the manifest prefix so an interrupted
        // prefetch can resume. `r2Prefix` is path-like (e.g.
        // "v2/org__name/version"); flatten it to a single safe component.
        let stagingName = ".prefetch-staging-" + manifest.r2Prefix
            .replacingOccurrences(of: "/", with: "__")
            .replacingOccurrences(of: "\\", with: "__")
        let stagingDir = snapshotsDir.appendingPathComponent(stagingName, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let jobs = try manifest.files.map { file -> (file: ManifestFile, destination: URL, url: String) in
            let relativePath = try Self.validatedManifestRelativePath(file.path)
            return (
                file: file,
                destination: stagingDir.appendingPathComponent(relativePath, isDirectory: false),
                url: "\(r2CDNURL)/\(Self.escapeR2Path(manifest.r2Prefix))/\(Self.escapeR2Path(relativePath))"
            )
        }

        // Classify each file once (hashing is expensive) into already-valid vs
        // still-needed. Reused for both progress seeding and the capacity check.
        let alreadyValid = jobs.map { Self.fileMatches($0.destination, size: $0.file.sizeBytes, sha256: $0.file.sha256) }

        // Bytes already verified on disk (resumed files) count toward progress
        // immediately. `progress` is updated as each file completes.
        let total = manifest.totalSizeBytes
        let progress = PrefetchByteProgress()
        for (job, valid) in zip(jobs, alreadyValid) where valid {
            progress.add(job.file.sizeBytes)
        }
        onByteProgress?(progress.done, total)

        // Capacity pre-check must account for already-staged bytes: on a resumed
        // prefetch most files are present + valid, so we only need free space for
        // the files we still have to download. Demanding the FULL model size here
        // would spuriously fail a resume that has plenty of room for what remains.
        // Publishing is a same-volume move of the staging dir, so staged bytes
        // need no extra headroom.
        // Count bytes already saved in each file's resumable `.part` so a tight-
        // disk resume isn't rejected for lacking room equal to a whole shard when
        // the byte-resume below will only append the missing suffix via `Range`.
        let partBytes = jobs.map { fileSize($0.destination.appendingPathExtension("part")) }
        let remainingBytes = Self.remainingBytesToFetch(
            sizes: jobs.map(\.file.sizeBytes),
            alreadyValid: alreadyValid,
            partBytes: partBytes
        )
        try Self.ensureAvailableCapacity(at: snapshotsDir, requiredBytes: remainingBytes)

        // Sequential downloads (one at a time) so prefetch yields to inference
        // and never saturates bandwidth the way the foreground 4-way concurrent
        // download does. Each file: skip-if-valid, else fetch + verify.
        for job in jobs {
            try Task.checkCancellation()
            if Self.fileMatches(job.destination, size: job.file.sizeBytes, sha256: job.file.sha256) {
                continue
            }
            try await downloadManifestFileWithResume(job)
            progress.add(job.file.sizeBytes)
            onByteProgress?(progress.done, total)
        }

        try Task.checkCancellation()

        // Aggregate hash over the staged files (same ordering rule as download).
        // Every per-file SHA already verified above, so reaching here with a
        // mismatch means the staged files are internally valid but do not match
        // the claimed aggregate — i.e. the manifest's aggregate is wrong/corrupt.
        // If we keep staging, `fileMatches` would skip all files on every future
        // attempt and re-fail the aggregate forever (a permanent poison state).
        // Clear staging so a corrected manifest re-downloads cleanly. (Per-file
        // and network/transport failures throw BEFORE this point and deliberately
        // leave staging intact so they can resume — only the aggregate-mismatch
        // path clears it.)
        let aggregate = WeightHasher.hashFilesWithRelativeKey(jobs.map { (file: $0.destination, sortKey: $0.file.path) })
        guard aggregate == manifest.aggregateSHA256 else {
            try? FileManager.default.removeItem(at: stagingDir)
            throw ModelCatalogError.downloadFailed("aggregate hash mismatch for \(model.id)")
        }

        try Self.publishStagedSnapshot(stagingDir, to: cacheDir)
        try writeMainRef(for: model.id)
        // Staging was consumed by publishStagedSnapshot (moved/replaced); make a
        // best-effort cleanup in case the platform left a husk behind.
        try? FileManager.default.removeItem(at: stagingDir)
        onByteProgress?(total, total)
    }

    /// Whether an interrupted foreground download left resumable content staged on
    /// disk for this model build (keyed by `r2Prefix`): a completed shard or a
    /// `.part` prefix in the stable `.local-staging-…` dir. Lets the picker show
    /// "resuming" instead of "not downloaded" for a partially-downloaded model so
    /// re-selecting it FINISHES the download rather than appearing to start over.
    public static func hasResumableStaging(modelID: String, r2Prefix: String) -> Bool {
        let stagingDir = cacheModelDirectory(for: modelID)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(localStagingDirName(r2Prefix: r2Prefix), isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: stagingDir.path) else {
            return false
        }
        // Any non-hidden staged entry (a finished file, a `.part`, or a nested
        // subdir like `adapters/`) is resumable content worth finishing.
        return entries.contains { !$0.hasPrefix(".") }
    }

    static func parseShardNames(indexPath: URL) throws -> [String] {
        let data = try Data(contentsOf: indexPath)
        let any = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = any as? [String: Any],
              let weightMap = dict["weight_map"] as? [String: String]
        else {
            throw ModelCatalogError.downloadFailed(
                "model.safetensors.index.json missing weight_map"
            )
        }
        let unique = Set(weightMap.values)
        return unique.sorted()
    }

    /// Bytes still to fetch on a (possibly resumed) prefetch/download. For each
    /// file not already fully valid on disk, this is its size MINUS any bytes
    /// already saved in its resumable `.part` file — a byte-resume appends to that
    /// prefix via HTTP `Range`, so those bytes don't need re-downloading and must
    /// not be charged against free disk (otherwise a near-complete resume of a big
    /// shard is rejected for lacking room equal to the whole shard).
    /// `partBytes[i]` is the size of file i's `.part` (0 if none / not resumable);
    /// each term is floored at 0 so a stale over-long `.part` can't go negative.
    /// Omitting `partBytes` degrades to "sum of not-yet-valid file sizes".
    static func remainingBytesToFetch(sizes: [Int64], alreadyValid: [Bool], partBytes: [Int64] = []) -> Int64 {
        var total: Int64 = 0
        for i in sizes.indices {
            if i < alreadyValid.count, alreadyValid[i] { continue }
            let have = i < partBytes.count ? max(0, partBytes[i]) : 0
            total += max(0, sizes[i] - have)
        }
        return total
    }

    internal static func ensureAvailableCapacity(at directory: URL, requiredBytes: Int64) throws {
        guard requiredBytes > 0 else { return }
        let plan = ModelDownloadStoragePlan(
            remainingBytes: requiredBytes,
            reserveBytes: 0,
            availableBytes: try availableCapacity(at: directory)
        )
        guard plan.hasSufficientCapacity else {
            throw ModelCatalogError.downloadFailed(
                "insufficient disk space: need \(requiredBytes) bytes, available \(plan.availableBytes ?? 0) bytes"
            )
        }
    }
}

// MARK: - Prefetch byte-progress accumulator

/// Tiny thread-safe cumulative byte counter for prefetch progress. The
/// per-file downloads run sequentially, but the accumulator is `Sendable` so it
/// can be read from progress callbacks without data races.
private final class PrefetchByteProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _done: Int64 = 0
    func add(_ bytes: Int64) { lock.lock(); _done += bytes; lock.unlock() }
    var done: Int64 { lock.lock(); defer { lock.unlock() }; return _done }
}
