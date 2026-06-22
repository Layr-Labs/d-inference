/// ModelDownloader download orchestration: manifest + legacy CDN download
/// flows (fetch manifest, per-file resume, staged finalize, publish).

import Foundation

extension ModelDownloader {
    /// Whether a file at `url` already exists with the expected size and SHA-256.
    /// Used by prefetch resume to skip already-valid files.
    static func fileMatches(_ url: URL, size: Int64, sha256: String) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let onDisk = attrs[.size] as? Int64, onDisk == size else {
            return false
        }
        guard let digest = WeightHasher.hashSingleFile(at: url) else { return false }
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex == sha256.lowercased()
    }

    /// Download a single manifest file into its staging destination, resuming
    /// from a `.part` file when present, verifying size + SHA-256 before
    /// promoting to the final staged path. Reuses the resume-capable
    /// `downloadFile` helper (Range requests, Content-Range validation, retries).
    ///
    /// `onChunk(bytesOnDisk)` reports cumulative bytes-on-disk for this file as
    /// it streams, so the foreground path can render a live per-shard bar; the
    /// background prefetch passes nil and accounts progress per whole file.
    internal func downloadManifestFileWithResume(
        _ job: (file: ManifestFile, destination: URL, url: String),
        onChunk: (@Sendable (Int64) -> Void)? = nil
    ) async throws {
        let ok = try await downloadFile(
            from: job.url,
            to: job.destination,
            label: job.file.path,
            onProgress: nil,
            required: true,
            expectedSHA256: job.file.sha256.lowercased(),
            onChunk: onChunk
        )
        guard ok else {
            throw ModelCatalogError.downloadFailed("\(job.file.path): required file could not be fetched")
        }
        let size = fileSize(job.destination)
        guard size == job.file.sizeBytes else {
            throw ModelCatalogError.downloadFailed("\(job.file.path): size \(size) != manifest size \(job.file.sizeBytes)")
        }
    }

    internal func fetchManifestFromCDN(model: CatalogModel) async throws -> ModelManifest {
        guard let r2Prefix = model.r2Prefix else {
            throw ModelCatalogError.downloadFailed("model missing r2_prefix")
        }
        let urlString = "\(r2CDNURL)/\(Self.escapeR2Path(r2Prefix))/manifest.json"
        guard let url = URL(string: urlString) else {
            throw ModelCatalogError.downloadFailed("invalid manifest URL: \(urlString)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw ModelCatalogError.downloadFailed("manifest.json: \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ModelCatalogError.downloadFailed("manifest.json: HTTP \(http.statusCode)")
        }

        do {
            return try ModelCatalogClient.manifestDecoder.decode(ModelManifest.self, from: data)
        } catch {
            throw ModelCatalogError.downloadFailed("manifest.json decode failed: \(error.localizedDescription)")
        }
    }

    internal func downloadLegacyModelFromCDN(
        model: CatalogModel,
        onProgress: (@Sendable (ProgressEvent) -> Void)?
    ) async throws {
        let cacheDir = Self.cacheSnapshotDirectory(for: model.id)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let base = "\(r2CDNURL)/\(model.s3Name)"

        // 1. config.json (smoke-test the model exists on the CDN).
        try await downloadFile(
            from: "\(base)/config.json",
            to: cacheDir.appendingPathComponent("config.json"),
            label: "config.json",
            onProgress: onProgress,
            required: true
        )

        // 2. tokenizer files. Best-effort.
        for name in ["tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "tokenizer.model", "chat_template.jinja"] {
            _ = try? await downloadFile(
                from: "\(base)/\(name)",
                to: cacheDir.appendingPathComponent(name),
                label: name,
                onProgress: onProgress,
                required: false
            )
        }

        // 3. Single safetensors? If a HEAD request returns 200 we go that route.
        if try await urlExists("\(base)/model.safetensors") {
            try await downloadFile(
                from: "\(base)/model.safetensors",
                to: cacheDir.appendingPathComponent("model.safetensors"),
                label: "model.safetensors",
                onProgress: onProgress,
                required: true
            )
        } else {
            // 4. Sharded model. Pull the index, then each shard listed in
            // `weight_map`.
            let indexPath = cacheDir.appendingPathComponent("model.safetensors.index.json")
            try await downloadFile(
                from: "\(base)/model.safetensors.index.json",
                to: indexPath,
                label: "model.safetensors.index.json",
                onProgress: onProgress,
                required: true
            )
            let shards = try Self.parseShardNames(indexPath: indexPath)
            for shard in shards {
                try await downloadFile(
                    from: "\(base)/\(shard)",
                    to: cacheDir.appendingPathComponent(shard),
                    label: shard,
                    onProgress: onProgress,
                    required: true
                )
            }
        }

        try writeMainRef(for: model.id)
    }

    internal func downloadManifestModel(
        model: CatalogModel,
        manifest: ModelManifest,
        onProgress: (@Sendable (ProgressEvent) -> Void)?
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

        // STABLE staging dir keyed by the manifest prefix (NOT a random UUID) so an
        // interrupted foreground download resumes: already-completed files are
        // skipped and partially-fetched shards continue from their `.part` instead
        // of re-fetching the whole model. Same resume contract as the background
        // `prefetch` path: staging is kept on a transient failure and cleared only
        // on an aggregate-hash mismatch (poison) below.
        let stagingDir = snapshotsDir.appendingPathComponent(
            Self.localStagingDirName(r2Prefix: manifest.r2Prefix), isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let jobs = try manifest.files.map { file -> (file: ManifestFile, destination: URL, url: String) in
            let relativePath = try Self.validatedManifestRelativePath(file.path)
            return (
                file: file,
                destination: stagingDir.appendingPathComponent(relativePath, isDirectory: false),
                url: "\(r2CDNURL)/\(Self.escapeR2Path(manifest.r2Prefix))/\(Self.escapeR2Path(relativePath))"
            )
        }

        // Resume: skip files already staged + valid; only the not-yet-valid files
        // are enqueued below.
        let alreadyValid = jobs.map { Self.fileMatches($0.destination, size: $0.file.sizeBytes, sha256: $0.file.sha256) }
        // The foreground per-file downloader now byte-resumes (streams to a stable
        // `.part` and appends via HTTP `Range`), so credit any bytes already saved
        // in each `.part`: a near-complete resume of a big shard must not be charged
        // disk room equal to the whole shard.
        let partBytes = jobs.map { fileSize($0.destination.appendingPathExtension("part")) }
        try Self.ensureAvailableCapacity(
            at: snapshotsDir,
            requiredBytes: Self.remainingBytesToFetch(
                sizes: jobs.map(\.file.sizeBytes), alreadyValid: alreadyValid, partBytes: partBytes
            )
        )
        let pending = zip(jobs, alreadyValid).filter { !$0.1 }.map(\.0)

        // FINISH-ON-RESTART: a prior run already staged every shard size+SHA-valid
        // but was killed before publishing (the hidden staging dir is invisible to
        // the scanner, so the picker showed "not downloaded"). Don't re-download —
        // verify the aggregate and publish.
        if pending.isEmpty {
            try finalizeStagedManifest(model: model, manifest: manifest, jobs: jobs, stagingDir: stagingDir, cacheDir: cacheDir)
            onProgress?(ProgressEvent(file: model.id, bytesDownloaded: manifest.totalSizeBytes, bytesTotal: manifest.totalSizeBytes))
            return
        }

        // Live per-shard progress. Seed each pending file's bar with any bytes
        // already saved in its `.part` (a resumed prefix) so the display reflects
        // real on-disk progress instead of restarting the bar at 0%.
        let progress = ManifestDownloadProgress()
        for job in pending {
            progress.register(
                label: job.file.path,
                expectedBytes: job.file.sizeBytes,
                initialBytes: fileSize(job.destination.appendingPathExtension("part"))
            )
        }

        let renderer = ProgressRenderer()
        // Start the render loop as a detached task.
        let renderTask = Task.detached { [renderer, progress] in
            while !Task.isCancelled {
                renderer.render(progress.allProgress)
                try? await Task.sleep(nanoseconds: 250_000_000)  // 250ms
            }
        }

        do {
            // 4-way concurrent download; each shard streams to its own `.part` and
            // resumes from it via a `Range` request after an interruption.
            try await withThrowingTaskGroup(of: Void.self) { group in
                var next = 0
                for _ in 0..<min(concurrency, pending.count) {
                    let job = pending[next]
                    next += 1
                    group.addTask {
                        try await self.downloadManifestFileWithResume(job, onChunk: { bytes in
                            progress.update(label: job.file.path, downloadedBytes: bytes)
                        })
                        progress.complete(label: job.file.path)
                    }
                }

                while try await group.next() != nil {
                    if next < pending.count {
                        let job = pending[next]
                        next += 1
                        group.addTask {
                            try await self.downloadManifestFileWithResume(job, onChunk: { bytes in
                                progress.update(label: job.file.path, downloadedBytes: bytes)
                            })
                            progress.complete(label: job.file.path)
                        }
                    }
                }
            }

            // Stop the render loop and print the final summary.
            renderTask.cancel()
            renderer.finish(progress.allProgress)
        } catch {
            renderTask.cancel()
            // One last render so the user sees where things stopped.
            renderer.render(progress.allProgress)
            // Keep staging ONLY if it holds resumable content (a completed file or
            // a `.part` prefix); otherwise remove the empty husk so a first-file
            // failure doesn't leave a stray staging dir behind. (A promoted file is
            // full-size + SHA-verified; size/SHA failures delete the `.part` first.)
            let hasResumable = jobs.contains {
                fileSize($0.destination) == $0.file.sizeBytes
                    || fileSize($0.destination.appendingPathExtension("part")) > 0
            }
            if !hasResumable {
                try? FileManager.default.removeItem(at: stagingDir)
            }
            throw error
        }

        try finalizeStagedManifest(model: model, manifest: manifest, jobs: jobs, stagingDir: stagingDir, cacheDir: cacheDir)
        onProgress?(ProgressEvent(file: model.id, bytesDownloaded: manifest.totalSizeBytes, bytesTotal: manifest.totalSizeBytes))
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
    private func finalizeStagedManifest(
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
