import Foundation

/// Streams an HTTP GET body straight to a `.part` file in OS-sized chunks using
/// the `URLSession` data-delegate callbacks.
///
/// This replaces `URLSession.AsyncBytes`, whose `for await byte in …` yields a
/// single `UInt8` per async-iterator step. That is pathologically slow for the
/// multi-GB model shards we download (one async resumption per byte → billions
/// of them per file). `URLSession.bytes` only exposes a per-byte sequence, so to
/// get OS-sized `Data` chunks we drop to the delegate API.
///
/// Backpressure — the one virtue of `AsyncBytes` we must NOT lose — is preserved
/// without any in-memory queue: `URLSession` serializes delegate callbacks and
/// does not invoke `urlSession(_:dataTask:didReceive:)` again until the previous
/// call returns. Writing each chunk synchronously to disk here therefore
/// throttles the socket to disk speed; nothing is buffered beyond the single
/// chunk the system hands us (so no drops and no unbounded growth on a slow
/// disk / fast network).
///
/// The resume contract matches the previous `streamDownload` implementation:
/// - If `existingBytes > 0` the caller sent `Range: bytes=N-`.
/// - 206 whose `Content-Range` start == N → append to the existing prefix.
/// - 200 (range ignored) or a mismatched/unverifiable 206 → truncate and rewrite
///   THIS file from byte 0.
/// - 404/403 → `.notFound` (caller removes the `.part`; throws iff required).
/// - 416 with a prefix → `.completeBeyondRange` (the `.part` already holds the
///   whole object; caller verifies + promotes it instead of re-downloading).
/// - A mid-stream transport drop leaves every received byte durably in `.part`
///   and surfaces as a thrown error so the caller retries with a fresh `Range`.
/// - Cooperative cancellation (`task.cancel()`) surfaces as `CancellationError`
///   and likewise leaves a resumable `.part`.
final class StreamingFileDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome {
        /// Body streamed to `.part` successfully (appended or rewritten).
        case success
        /// 416: the `.part` is already at/beyond the object length.
        case completeBeyondRange
        /// 404/403 for an optional file.
        case notFound(Int)
    }

    private let partial: URL
    private let existingBytes: Int64
    private let label: String
    private let onChunk: (@Sendable (Int64) -> Void)?
    private let fm = FileManager.default

    // Mutated only from the URLSession delegate queue (callbacks are serialized).
    private var writer: FileHandle?
    private var baseline: Int64 = 0
    private var written: Int64 = 0
    private var decided: Outcome?
    private var setupError: Error?

    // The continuation may be resumed from any delegate callback; guard it.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Error>?
    private var resumed = false

    init(
        partial: URL,
        existingBytes: Int64,
        label: String,
        onChunk: (@Sendable (Int64) -> Void)?
    ) {
        self.partial = partial
        self.existingBytes = existingBytes
        self.label = label
        self.onChunk = onChunk
        super.init()
    }

    /// Attach the awaiting continuation. Call exactly once, immediately before
    /// `task.resume()`.
    func attach(_ continuation: CheckedContinuation<Outcome, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    private func finish(_ result: Result<Outcome, Error>) {
        lock.lock()
        guard !resumed, let cont = continuation else { lock.unlock(); return }
        resumed = true
        continuation = nil
        lock.unlock()
        switch result {
        case .success(let outcome): cont.resume(returning: outcome)
        case .failure(let error): cont.resume(throwing: error)
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            setupError = ModelCatalogError.downloadFailed("\(label): unexpected response type")
            completionHandler(.cancel)
            return
        }
        let status = http.statusCode

        if status == 404 || status == 403 {
            decided = .notFound(status)
            completionHandler(.cancel)
            return
        }
        // 416 Range Not Satisfiable: we asked for bytes past EOF, so the `.part`
        // already holds the whole file. Let the caller verify + promote it.
        if status == 416, existingBytes > 0 {
            decided = .completeBeyondRange
            completionHandler(.cancel)
            return
        }
        guard (200..<300).contains(status) else {
            setupError = ModelCatalogError.downloadFailed("\(label): HTTP \(status)")
            completionHandler(.cancel)
            return
        }

        // Append only when the server confirms it resumed at our exact offset.
        var append = false
        if existingBytes > 0, status == 206,
            let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
            let start = Self.parseContentRangeStart(contentRange),
            start == UInt64(existingBytes) {
            append = true
        }

        do {
            if !append { try? fm.removeItem(at: partial) }
            if !fm.fileExists(atPath: partial.path) {
                fm.createFile(atPath: partial.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: partial)
            if append {
                try handle.seekToEnd()
            } else {
                try handle.truncate(atOffset: 0)
            }
            writer = handle
            baseline = append ? existingBytes : 0
        } catch {
            setupError = ModelCatalogError.downloadFailed(
                "\(label): could not open .part for writing (\(error.localizedDescription))")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard setupError == nil, let writer else { return }
        do {
            // Synchronous write == backpressure: the next didReceive(data:) is
            // not delivered until this returns, throttling the socket to disk.
            try writer.write(contentsOf: data)
            written += Int64(data.count)
            onChunk?(baseline + written)
        } catch {
            setupError = ModelCatalogError.downloadFailed(
                "\(label): write failed (\(error.localizedDescription))")
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? writer?.close()
        writer = nil

        // Decisions taken during response handling win over the cancellation
        // error that our own `completionHandler(.cancel)` produces.
        if let setupError {
            finish(.failure(setupError))
            return
        }
        if let decided {
            finish(.success(decided))
            return
        }
        if let error {
            if (error as? URLError)?.code == .cancelled {
                finish(.failure(CancellationError()))
            } else {
                // Transport drop mid-stream: the prefix stays in `.part`.
                finish(.failure(error))
            }
            return
        }
        onChunk?(baseline + written)
        finish(.success(.success))
    }

    /// Parse the start offset from a `Content-Range` value, e.g.
    /// "bytes 12345-67890/123456".
    static func parseContentRangeStart(_ value: String) -> UInt64? {
        guard value.hasPrefix("bytes ") else { return nil }
        let afterBytes = value.dropFirst("bytes ".count)
        guard let dashIndex = afterBytes.firstIndex(of: "-") else { return nil }
        return UInt64(afterBytes[afterBytes.startIndex..<dashIndex])
    }
}
