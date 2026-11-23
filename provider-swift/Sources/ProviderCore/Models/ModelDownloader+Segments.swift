/// ModelDownloader ranged transfer of one large manifest file: a ranged probe,
/// then several byte ranges at once, each over its own connection, into a
/// pre-sized `.part` (`SegmentedPartFile`, written by `SegmentedPartWriter`),
/// verified by the file's SHA-256 before it is promoted. Everything else takes
/// the single-stream `downloadFile`.

import Foundation

extension ModelDownloader {
    /// How a ranged transfer of one file ended, when it did not throw.
    enum SegmentedOutcome {
        /// Verified and promoted.
        case promoted
        /// A range request showed that the source does not serve the file's
        /// ranges (`RangesRefused`); the `.part` and its record are kept.
        case rangesRefused
        /// The whole file failed its SHA-256; the `.part` and its record are deleted.
        case digestMismatch(String)
    }

    /// Fetch one manifest file from one source into `job.destination`. Over
    /// `segmentsPerFile` ranges when that is above 1, the file is at least
    /// `segmentMinimumFileBytes`, its volume keeps files sparse
    /// (`sparseFilesSupported`) and the source answers a ranged probe with a
    /// 206 for exactly the manifest size; otherwise the single-stream
    /// `downloadFile`, after reducing a ranged `.part` to its gap-free prefix.
    /// The single stream also takes over when a range request shows that the
    /// source does not serve ranges after all, and after a ranged file fails
    /// its SHA-256, with the source's attempts that are left (none for one
    /// attempt, which then fails as before).
    func fetchManifestFile(
        _ job: (file: ManifestFile, destination: URL, url: String),
        from urlString: String,
        attempts: Int = ModelDownloader.defaultAttempts,
        requestTimeout: TimeInterval = ModelDownloader.defaultRequestTimeout,
        onChunk: (@Sendable (Int64) -> Void)?
    ) async throws -> Bool {
        let partial = job.destination.appendingPathExtension("part")
        let size = job.file.sizeBytes
        var singleStreamAttempts = attempts
        let directory = job.destination.deletingLastPathComponent()
        if segmentsPerFile > 1, size >= segmentMinimumFileBytes, let url = URL(string: urlString),
           (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
           sparseFilesSupported(directory),
           try await servesRanges(url, size: size, label: job.file.path, attempts: attempts, requestTimeout: requestTimeout) {
            switch try await downloadInSegments(job, from: url, attempts: attempts, requestTimeout: requestTimeout,
                                                onChunk: onChunk) {
            case .promoted:
                return true
            case .rangesRefused:
                break
            case .digestMismatch(let detail):
                singleStreamAttempts = attempts - 1
                guard singleStreamAttempts > 0 else { throw ModelCatalogError.downloadFailed(detail) }
            }
        }
        try SegmentedPartFile.collapseToPrefix(partial: partial, size: size)
        return try await downloadFile(
            from: urlString, to: job.destination, label: job.file.path, onProgress: nil, required: true,
            expectedSHA256: job.file.sha256.lowercased(), maximumBytes: size, attempts: singleStreamAttempts,
            requestTimeout: requestTimeout, onChunk: onChunk)
    }

    /// Whether `url` serves byte ranges of a `size`-byte object: a GET of byte
    /// 0 answered 206 with a `Content-Range` total of `size`, after redirects.
    /// A 200, a 4xx (a 416, a proxy refusing `Range`, a missing file, which the
    /// single stream then reports) or another total is false; a transport
    /// error or another status is retried, then thrown.
    private func servesRanges(
        _ url: URL, size: Int64, label: String, attempts: Int, requestTimeout: TimeInterval
    ) async throws -> Bool {
        let request = rangeRequest(url, bytes: "0-0", requestTimeout: requestTimeout)
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
                if http.statusCode == 200 || (400..<500).contains(http.statusCode) { return false }
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

    /// Fetch the ranges the `.part`'s record still needs, at most
    /// `segmentsPerFile` at once (a record saved under a larger count queues
    /// the rest), then verify and promote the file.
    private func downloadInSegments(
        _ job: (file: ManifestFile, destination: URL, url: String),
        from url: URL,
        attempts: Int,
        requestTimeout: TimeInterval,
        onChunk: (@Sendable (Int64) -> Void)?
    ) async throws -> SegmentedOutcome {
        let label = job.file.path
        let size = job.file.sizeBytes
        let partial = job.destination.appendingPathExtension("part")
        try FileManager.default.createDirectory(
            at: job.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let layout = try SegmentedPartFile.prepare(partial: partial, size: size, count: segmentsPerFile)
        let writer = try SegmentedPartWriter(partial: partial, layout: layout, uncached: uncachedWrites, onChunk: onChunk)
        segmentedWriterOpened?(writer)
        let unfinished = layout.ranges.indices.filter { !layout.ranges[$0].isComplete }
        let fetch: @Sendable (Int) async throws -> Void = { index in
            try await self.fetchRange(index, into: writer, from: url, label: label,
                                      attempts: attempts, requestTimeout: requestTimeout)
        }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var next = 0
                for _ in 0..<min(segmentsPerFile, unfinished.count) {
                    let index = unfinished[next]
                    next += 1
                    group.addTask { try await fetch(index) }
                }
                while try await group.next() != nil {
                    if next < unfinished.count {
                        let index = unfinished[next]
                        next += 1
                        group.addTask { try await fetch(index) }
                    }
                }
            }
            try writer.close()
        } catch is RangesRefused {
            try? writer.close()
            return .rangesRefused
        } catch {
            try? writer.close()
            throw error
        }

        let expected = job.file.sha256.lowercased()
        let actual = verificationSHA256Hex(of: partial)
        guard actual == expected else {
            try SegmentedPartFile.remove(partial: partial)
            return .digestMismatch(
                "\(label): SHA-256 mismatch (size=\(size), expected=\(expected.prefix(16))…, got=\(actual.prefix(16))…)")
        }
        // Record first: a `.part` without one is a prefix, and this one is whole.
        try SegmentedPartFile.removeRecord(partial: partial)
        try? FileManager.default.removeItem(at: job.destination)
        try FileManager.default.moveItem(at: partial, to: job.destination)
        onChunk?(size)
        return .promoted
    }

    /// Fetch what range `index` still needs over a connection of its own: a
    /// session per range, so the ranges are separate connections rather than
    /// streams of one. An attempt that wrote bytes is retried at once from
    /// where it stopped; the range fails after `attempts` attempts in a row
    /// that wrote none. `RangesRefused` is never retried.
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
            } catch let refused as RangesRefused {
                throw refused
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
        let request = rangeRequest(url, bytes: "\(range.lowerBound)-\(range.upperBound - 1)", requestTimeout: requestTimeout)
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

    /// A GET of `bytes` (`first-last`) without content coding, so `Content-Range`
    /// offsets are the delivered bytes', idle for at most
    /// `ModelDownloadSegments.rangeRequestTimeout`, and of the background network
    /// service type under `backgroundRanges`.
    private func rangeRequest(_ url: URL, bytes: String, requestTimeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = min(requestTimeout, ModelDownloadSegments.rangeRequestTimeout)
        request.setValue("bytes=\(bytes)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if backgroundRanges { request.networkServiceType = .background }
        return request
    }
}
