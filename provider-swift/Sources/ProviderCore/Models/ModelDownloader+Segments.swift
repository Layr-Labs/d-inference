/// ModelDownloader ranged transfer of one large manifest file: a ranged probe,
/// then several byte ranges at once, each over its own connection, into a
/// pre-sized `.part` (`SegmentedPartFile`), verified by the file's SHA-256
/// before it is promoted. Everything else takes the single-stream
/// `downloadFile`.

import Darwin
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
        // RED CONTROL: the single-stream download only, as before the change.
        let size = job.file.sizeBytes
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
        let actual = uncachedWrites ? (Self.sha256Uncached(partial).map(Self.hex) ?? "<unreadable>")
                                    : Self.sha256HexForVerification(of: partial)
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
        var lastError: Error?
        while let remaining = writer.remaining(index) {
            try Task.checkCancellation()
            let before = remaining.lowerBound
            do {
                try await streamRange(remaining, of: index, into: writer, session: session, url: url,
                                      label: label, requestTimeout: requestTimeout)
                if writer.remaining(index) == nil { return }
                lastError = ModelCatalogError.downloadFailed("\(label): bytes \(before)- ended early")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                if (error as? URLError)?.code == .cancelled { throw error }
                lastError = error
            }
            if let now = writer.remaining(index)?.lowerBound, now > before {
                fruitless = 0
                continue
            }
            fruitless += 1
            guard fruitless < attempts else { break }
            try await taskSleep(retryBackoff * fruitless)
        }
        if writer.remaining(index) == nil { return }
        throw ModelCatalogError.downloadFailed(Self.downloadFailureMessage(label: label, error: lastError))
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

/// Writes the ranges of one ranged download into its pre-sized `.part` and
/// keeps its record (`SegmentedPartFile`). Bytes are written at each range's
/// next offset; the record is saved only after the `.part` is synced, so it
/// never counts a byte that is not on disk. Progress (`onChunk`) is the sum of
/// every range's bytes, reported in order under one lock, so it only grows.
final class SegmentedPartWriter: @unchecked Sendable {
    /// Bytes written between two saves of the record.
    static let checkpointBytes: Int64 = 32 << 20

    let size: Int64
    /// The `.part`'s descriptor took `F_NOCACHE`: every `pwrite` on it skips the file cache.
    let cachingDisabled: Bool
    private let partial: URL
    private let descriptor: Int32
    private let onChunk: (@Sendable (Int64) -> Void)?

    private let lock = NSLock()
    private var layout: SegmentedPartLayout
    private var unsavedBytes: Int64 = 0
    private var closed = false
    /// Serializes record saves, so a later save never precedes an earlier one.
    private let checkpointLock = NSLock()

    init(partial: URL, layout: SegmentedPartLayout, uncached: Bool, onChunk: (@Sendable (Int64) -> Void)?) throws {
        let descriptor = Darwin.open(partial.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ModelCatalogError.downloadFailed(
                "\(partial.lastPathComponent): could not open for writing (\(String(cString: strerror(errno))))")
        }
        self.descriptor = descriptor
        self.cachingDisabled = uncached && fcntl(descriptor, F_NOCACHE, 1) == 0
        self.partial = partial
        self.layout = layout
        self.size = layout.size
        self.onChunk = onChunk
        onChunk?(layout.doneBytes)
    }

    /// The bytes range `index` still needs; nil once it is complete.
    func remaining(_ index: Int) -> Range<Int64>? {
        lock.withLock {
            let range = layout.ranges[index]
            return range.isComplete ? nil : range.next..<range.end
        }
    }

    /// Write `data` at range `index`'s next offset. Only that range's one
    /// request calls this, one chunk at a time.
    func write(_ data: Data, range index: Int) throws {
        let (offset, end, open) = lock.withLock { (layout.ranges[index].next, layout.ranges[index].end, !closed) }
        let count = Int64(data.count)
        guard open else { throw CancellationError() }
        guard count <= end - offset else {
            throw ModelCatalogError.downloadFailed("\(partial.lastPathComponent): response exceeds its byte range")
        }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var written = 0
            while written < buffer.count {
                let result = Darwin.pwrite(descriptor, buffer.baseAddress! + written, buffer.count - written,
                                           off_t(offset) + off_t(written))
                if result < 0 {
                    if errno == EINTR { continue }
                    throw ModelCatalogError.downloadFailed(
                        "\(partial.lastPathComponent): write failed (\(String(cString: strerror(errno))))")
                }
                written += result
            }
        }
        let checkpointDue: Bool = lock.withLock {
            layout.ranges[index].done += count
            onChunk?(layout.doneBytes)
            unsavedBytes += count
            guard unsavedBytes >= Self.checkpointBytes else { return false }
            unsavedBytes = 0
            return true
        }
        if checkpointDue { try checkpoint() }
    }

    /// Sync the `.part`, then save the record of what was written before the sync.
    func checkpoint() throws {
        try checkpointLock.withLock {
            let snapshot = lock.withLock { layout }
            guard fsync(descriptor) == 0 else {
                throw ModelCatalogError.downloadFailed(
                    "\(partial.lastPathComponent): sync failed (\(String(cString: strerror(errno))))")
            }
            try SegmentedPartFile.save(snapshot, partial: partial)
        }
    }

    /// Save the record a last time and close the `.part`. Idempotent.
    func close() throws {
        let first = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        defer { Darwin.close(descriptor) }
        try checkpoint()
    }
}
