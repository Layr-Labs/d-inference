/// ModelDownloader download orchestration: the verified-manifest download
/// flow (fetch manifest, per-file resume, staged finalize, publish).

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

    internal func downloadManifestModel(
        model: CatalogModel,
        manifest: ModelManifest,
        onProgress: (@Sendable (ProgressEvent) -> Void)?
    ) async throws {
        try Self.validateArtifactManifest(manifest, model: model)
        let cacheDir = try Self.revisionSnapshotDirectory(manifest: manifest)
        if try Self.verifyRevisionAndRepairReceipt(at: cacheDir, manifest: manifest) {
            try Self.activateRevision(modelID: model.id, directory: cacheDir)
            progressRenderer(model: model, manifest: manifest, startBytes: manifest.totalSizeBytes)?.alreadyDownloaded()
            onProgress?(ProgressEvent(file: model.id, bytesDownloaded: manifest.totalSizeBytes, bytesTotal: manifest.totalSizeBytes))
            return
        }
        let snapshotsDir = cacheDir.deletingLastPathComponent()
        try Self.prepareModelCacheDirectory(at: snapshotsDir.deletingLastPathComponent())
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

        let jobs = try manifestJobs(manifest, stagingDir: stagingDir)

        try Self.reuseVerifiedFiles(modelID: model.id, manifest: manifest, stagingDir: stagingDir)

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
            try finalizeAndReport(model: model, manifest: manifest, jobs: jobs, stagingDir: stagingDir, cacheDir: cacheDir,
                                  renderer: progressRenderer(model: model, manifest: manifest, startBytes: manifest.totalSizeBytes))
            onProgress?(ProgressEvent(file: model.id, bytesDownloaded: manifest.totalSizeBytes, bytesTotal: manifest.totalSizeBytes))
            return
        }

        // Seed each pending file with any bytes already saved in its `.part` (a
        // resumed prefix) so progress starts from the real bytes on disk.
        let progress = ManifestDownloadProgress()
        for job in pending {
            progress.register(
                label: job.file.path,
                expectedBytes: job.file.sizeBytes,
                initialBytes: fileSize(job.destination.appendingPathExtension("part"))
            )
        }

        let alreadyValidBytes = zip(jobs, alreadyValid).reduce(Int64(0)) { $0 + ($1.1 ? $1.0.file.sizeBytes : 0) }
        let downloadedBytes: @Sendable () -> Int64 = { alreadyValidBytes + progress.downloadedBytes }
        let byteProgress = self.byteProgress
        let renderer = progressRenderer(model: model, manifest: manifest, startBytes: downloadedBytes())
        let renderTask = Task.detached {
            while !Task.isCancelled {
                let done = downloadedBytes()
                byteProgress?(done, manifest.totalSizeBytes)
                renderer?.update(done: done)
                try? await Task.sleep(nanoseconds: 250_000_000)  // 250ms
            }
        }

        let transfer: @Sendable ((file: ManifestFile, destination: URL, url: String)) async throws -> Void = { job in
            try await self.downloadManifestFileWithResume(job, huggingFaceArtifact: model.huggingFaceArtifact, onChunk: { bytes in
                progress.update(label: job.file.path, downloadedBytes: bytes)
            })
            progress.complete(label: job.file.path)
        }

        do {
            // 4-way concurrent download; each shard streams to its own `.part` and
            // resumes from it via a `Range` request after an interruption.
            try await withThrowingTaskGroup(of: Void.self) { group in
                var next = 0
                for _ in 0..<min(concurrency, pending.count) {
                    let job = pending[next]
                    next += 1
                    group.addTask { try await transfer(job) }
                }

                while try await group.next() != nil {
                    if next < pending.count {
                        let job = pending[next]
                        next += 1
                        group.addTask { try await transfer(job) }
                    }
                }
            }

            // Stop the render loop, waiting out an in-flight frame so none can
            // land below the lines that follow.
            renderTask.cancel()
            await renderTask.value
        } catch {
            renderTask.cancel()
            await renderTask.value
            renderer?.fail(done: downloadedBytes())
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

        // The loop's last sample can predate the last bytes; checking every file
        // takes a while on a large model, so report the complete count first.
        byteProgress?(downloadedBytes(), manifest.totalSizeBytes)
        try finalizeAndReport(model: model, manifest: manifest, jobs: jobs, stagingDir: stagingDir, cacheDir: cacheDir,
                              renderer: renderer)
        onProgress?(ProgressEvent(file: model.id, bytesDownloaded: manifest.totalSizeBytes, bytesTotal: manifest.totalSizeBytes))
    }

    /// The foreground download's progress line, unless a caller that shows the
    /// progress itself takes the counts (`byteProgress`).
    private func progressRenderer(model: CatalogModel, manifest: ModelManifest, startBytes: Int64) -> DownloadProgressRenderer? {
        guard byteProgress == nil else { return nil }
        return DownloadProgressRenderer(modelID: model.id, displayName: model.displayName,
                                        totalBytes: manifest.totalSizeBytes, startBytes: startBytes, terminal: progressTerminal)
    }

    /// Checks the staged files and publishes them (`finalizeStagedManifest`),
    /// with "Verifying …" and then the download's completion line or the failed
    /// check on `renderer`.
    private func finalizeAndReport(
        model: CatalogModel,
        manifest: ModelManifest,
        jobs: [(file: ManifestFile, destination: URL, url: String)],
        stagingDir: URL,
        cacheDir: URL,
        renderer: DownloadProgressRenderer?
    ) throws {
        renderer?.verifying()
        do {
            try finalizeStagedManifest(model: model, manifest: manifest, jobs: jobs, stagingDir: stagingDir, cacheDir: cacheDir)
        } catch {
            renderer?.verificationFailed(error)
            throw error
        }
        renderer?.finish()
    }
}
