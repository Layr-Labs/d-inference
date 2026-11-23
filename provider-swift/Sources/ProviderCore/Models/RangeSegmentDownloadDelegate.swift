import Foundation

/// Streams the body of one ranged GET of a model file into its byte range of
/// the shared `.part` (`ModelDownloader+Segments.swift`).
///
/// Only a 206 whose `Content-Range` is exactly the requested first byte, last
/// byte and manifest size is written; any other answer fails the attempt
/// before a byte lands, so no byte is placed where the server did not say it
/// belongs. Each chunk is handed to `write` synchronously, so the socket is
/// throttled to disk speed, as in `StreamingFileDownloadDelegate`. A transport
/// drop or a cancellation keeps every byte already written: `write` counted
/// them, and the writer's next checkpoint or `close()` saves them in the record.
final class RangeSegmentDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let label: String
    private let range: Range<Int64>
    private let totalBytes: Int64
    private let write: (Data) throws -> Void

    // Mutated only from the URLSession delegate queue (callbacks are serialized).
    private var accepted = false
    private var failure: Error?

    // Cancellation can complete a suspended URLSession task before attach runs.
    // Keep the first terminal result so either callback order resumes the waiter.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    init(label: String, range: Range<Int64>, totalBytes: Int64, write: @escaping (Data) throws -> Void) {
        self.label = label
        self.range = range
        self.totalBytes = totalBytes
        self.write = write
        super.init()
    }

    /// Attach the awaiting continuation. Call exactly once, immediately before
    /// `task.resume()`.
    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        let completed: Result<Void, Error>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let completed { continuation.resume(with: completed) }
    }

    private func finish(_ result: Result<Void, Error>) {
        let cont: CheckedContinuation<Void, Error>? = lock.withLock {
            guard self.result == nil else { return nil }
            self.result = result
            let cont = continuation
            continuation = nil
            return cont
        }
        cont?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        let contentRange = http?.value(forHTTPHeaderField: "Content-Range")
        let expected = (first: range.lowerBound, last: range.upperBound - 1, total: totalBytes)
        guard http?.statusCode == 206, let parsed = contentRange.flatMap(Self.parseContentRange),
              parsed.first == expected.first, parsed.last == expected.last, parsed.total == expected.total else {
            failure = ModelCatalogError.downloadFailed(
                "\(label): bytes \(expected.first)-\(expected.last) answered HTTP \(http?.statusCode ?? 0) "
                    + (contentRange.map { "with Content-Range \($0)" } ?? "without Content-Range"))
            completionHandler(.cancel)
            return
        }
        accepted = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard accepted, failure == nil else { return }
        do {
            try write(data)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let failure {
            finish(.failure(failure))
        } else if let error {
            finish(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : error))
        } else {
            finish(.success(()))
        }
    }

    /// The first byte, last byte and total of a satisfied `Content-Range`,
    /// e.g. "bytes 0-1048575/5368709120"; nil for any other form.
    static func parseContentRange(_ value: String) -> (first: Int64, last: Int64, total: Int64)? {
        guard value.hasPrefix("bytes ") else { return nil }
        let spec = value.dropFirst("bytes ".count).trimmingCharacters(in: .whitespaces)
        let halves = spec.split(separator: "/", omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let bounds = halves[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let first = Int64(bounds[0]), let last = Int64(bounds[1]),
              let total = Int64(halves[1]), first <= last, last < total else { return nil }
        return (first, last, total)
    }
}
