/// ModelDownloader ranged transfer of one large manifest file: a ranged probe,
/// then several byte ranges at once, each over its own connection, into a
/// pre-sized `.part` (`SegmentedPartFile`, written by `SegmentedPartWriter`),
/// verified by the file's SHA-256 before it is promoted. Everything else takes
/// the single-stream `downloadFile`.

import Foundation

extension ModelDownloader {
    /// Fetch one manifest file from one source into `job.destination`. Over
    /// `segmentsPerFile` ranges when that is above 1, the file is at least
    /// `segmentMinimumFileBytes` and the source answers a ranged probe with a
    /// 206 for exactly the manifest size; otherwise the single-stream
    /// `downloadFile`, after reducing a ranged `.part` to its gap-free prefix.
    func fetchManifestFile(
        _ job: (file: ManifestFile, destination: URL, url: String),
        from urlString: String,
        attempts: Int = ModelDownloader.defaultAttempts,
        requestTimeout: TimeInterval = ModelDownloader.defaultRequestTimeout,
        onChunk: (@Sendable (Int64) -> Void)?
    ) async throws -> Bool {
        let partial = job.destination.appendingPathExtension("part")
        let size = job.file.sizeBytes
        if segmentsPerFile > 1, size >= segmentMinimumFileBytes, let url = URL(string: urlString),
           try await servesRanges(url, size: size, label: job.file.path, attempts: attempts, requestTimeout: requestTimeout) {
            try await downloadInSegments(job, from: url, attempts: attempts, requestTimeout: requestTimeout, onChunk: onChunk)
            return true
        }
        try SegmentedPartFile.collapseToPrefix(partial: partial, size: size)
        return try await downloadFile(
            from: urlString, to: job.destination, label: job.file.path, onProgress: nil, required: true,
            expectedSHA256: job.file.sha256.lowercased(), maximumBytes: size, attempts: attempts,
            requestTimeout: requestTimeout, onChunk: onChunk)
    }

    /// Whether `url` serves byte ranges of a `size`-byte object: a GET of byte
    /// 0 answered 206 with a `Content-Range` total of `size`, after redirects.
    /// A 200 or another total is false; a failed request is retried, then thrown.
    private func servesRanges(
        _ url: URL, size: Int64, label: String, attempts: Int, requestTimeout: TimeInterval
    ) async throws -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        var lastError: Error?
        for attempt in 1...max(1, attempts) {
            try Task.checkCancellation()
            do {
                // Headers only: a server that ignores the range would send the whole file.
                let (body, response) = try await urlSession.bytes(for: request)
                body.task.cancel()
                guard let http = response as? HTTPURLResponse else {
                    throw ModelCatalogError.downloadFailed("\(label): unexpected response type")
                }
                if http.statusCode == 200 { return false }
                guard http.statusCode == 206 else {
                    throw ModelCatalogError.downloadFailed("\(label): HTTP \(http.statusCode)")
                }
                let total = http.value(forHTTPHeaderField: "Content-Range")
                    .flatMap(RangeSegmentDownloadDelegate.parseContentRange)?.total
                return total == size
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                if (error as? URLError)?.code == .cancelled { throw error }
                lastError = error
                if attempt < attempts { try await taskSleep(retryBackoff * attempt) }
            }
        }
        throw ModelCatalogError.downloadFailed(Self.downloadFailureMessage(label: label, error: lastError))
    }

    private func downloadInSegments(
        _ job: (file: ManifestFile, destination: URL, url: String),
        from url: URL,
        attempts: Int,
        requestTimeout: TimeInterval,
        onChunk: (@Sendable (Int64) -> Void)?
    ) async throws {
        let label = job.file.path
        let size = job.file.sizeBytes
        let partial = job.destination.appendingPathExtension("part")
        try FileManager.default.createDirectory(
            at: job.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let layout = try SegmentedPartFile.prepare(partial: partial, size: size, count: segmentsPerFile)
        let writer = try SegmentedPartWriter(partial: partial, layout: layout, uncached: uncachedWrites, onChunk: onChunk)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in layout.ranges.indices where !layout.ranges[index].isComplete {
                    group.addTask {
                        try await self.fetchRange(index, into: writer, from: url, label: label,
                                                  attempts: attempts, requestTimeout: requestTimeout)
                    }
                }
                try await group.waitForAll()
            }
            try writer.close()
        } catch {
            try? writer.close()
            throw error
        }

        let expected = job.file.sha256.lowercased()
        let actual = verificationSHA256Hex(of: partial)
        guard actual == expected else {
            try? SegmentedPartFile.remove(partial: partial)
            throw ModelCatalogError.downloadFailed(
                "\(label): SHA-256 mismatch (size=\(size), expected=\(expected.prefix(16))…, got=\(actual.prefix(16))…)")
        }
        // Record first: a `.part` without one is a prefix, and this one is whole.
        try SegmentedPartFile.removeRecord(partial: partial)
        try? FileManager.default.removeItem(at: job.destination)
        try FileManager.default.moveItem(at: partial, to: job.destination)
        onChunk?(size)
    }

    /// Fetch what range `index` still needs over a connection of its own: a
    /// session per range, so the ranges are separate connections rather than
    /// streams of one. An attempt that wrote bytes is retried at once from
    /// where it stopped; the range fails after `attempts` attempts in a row
    /// that wrote none.
    private func fetchRange(
        _ index: Int, into writer: SegmentedPartWriter, from url: URL, label: String,
        attempts: Int, requestTimeout: TimeInterval
    ) async throws {
        let session = URLSession(configuration: urlSession.configuration)
        defer { session.finishTasksAndInvalidate() }
        var fruitless = 0
        while let remaining = writer.remaining(index) {
            try Task.checkCancellation()
            let failure: Error
            do {
                try await streamRange(remaining, of: index, into: writer, session: session, url: url,
                                      label: label, requestTimeout: requestTimeout)
                failure = ModelCatalogError.downloadFailed(
                    "\(label): bytes \(remaining.lowerBound)-\(remaining.upperBound - 1) ended early")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                if (error as? URLError)?.code == .cancelled { throw error }
                failure = error
            }
            guard let now = writer.remaining(index) else { return }
            if now.lowerBound > remaining.lowerBound {
                fruitless = 0
                continue
            }
            fruitless += 1
            guard fruitless < attempts else {
                throw ModelCatalogError.downloadFailed(Self.downloadFailureMessage(label: label, error: failure))
            }
            try await taskSleep(retryBackoff * fruitless)
        }
    }

    private func streamRange(
        _ range: Range<Int64>, of index: Int, into writer: SegmentedPartWriter, session: URLSession,
        url: URL, label: String, requestTimeout: TimeInterval
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let delegate = RangeSegmentDownloadDelegate(label: label, range: range, totalBytes: writer.size) { data in
            try writer.write(data, range: index)
        }
        let task = session.dataTask(with: request)
        task.delegate = delegate
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                delegate.attach(cont)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}
