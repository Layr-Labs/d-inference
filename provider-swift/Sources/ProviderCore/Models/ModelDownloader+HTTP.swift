/// ModelDownloader HTTP/file IO + hashing: single-file fetch with byte
/// resume, raw stream-to-disk, existence probe, ref/publish, SHA-256.

import Foundation

extension ModelDownloader {
    internal func downloadFileForTesting(
        from urlString: String,
        to destination: URL,
        label: String = "test.bin",
        onProgress: (@Sendable (ProgressEvent) -> Void)? = nil,
        required: Bool = true
    ) async throws -> Bool {
        try await downloadFile(
            from: urlString,
            to: destination,
            label: label,
            onProgress: onProgress,
            required: required,
            expectedSHA256: nil
        )
    }

    internal func urlExists(_ urlString: String) async throws -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 10
        do {
            let (_, response) = try await urlSession.data(for: req)
            return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    @discardableResult
    internal func downloadFile(
        from urlString: String,
        to destination: URL,
        label: String,
        onProgress: (@Sendable (ProgressEvent) -> Void)?,
        required: Bool,
        expectedSHA256: String? = nil,
        onChunk: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> Bool {
        guard let url = URL(string: urlString) else {
            if required { throw ModelCatalogError.downloadFailed("invalid URL: \(urlString)") }
            return false
        }

        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("part")

        var lastError: Error?
        for attempt in 1...3 {
            do {
                // True byte-level resume: stream the HTTP body straight to the
                // `.part` file as bytes arrive (appending when a `.part` prefix
                // already exists), so a mid-stream connection drop leaves the
                // received prefix on disk and the next attempt picks up where it
                // left off via a `Range` request — never restarting from zero.
                let ok = try await streamDownload(
                    from: url,
                    to: partial,
                    label: label,
                    required: required,
                    onChunk: onChunk
                )
                guard ok else {
                    // Optional file that does not exist (404/403). `streamDownload`
                    // already removed any stale `.part`.
                    return false
                }

                if let expectedSHA256 {
                    let actual = Self.sha256HexForVerification(of: partial)
                    let size = fileSize(partial)
                    guard actual == expectedSHA256 else {
                        // The `.part` is corrupt (hash mismatch). Delete it so the
                        // next attempt re-fetches this file cleanly from byte 0
                        // rather than appending onto bad bytes forever.
                        try? fm.removeItem(at: partial)
                        throw ModelCatalogError.downloadFailed(
                            "\(label): SHA-256 mismatch (size=\(size), expected=\(expectedSHA256.prefix(16))…, got=\(actual.prefix(16))…)"
                        )
                    }
                }
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: partial, to: destination)
                let downloaded = fileSize(destination)
                onProgress?(ProgressEvent(file: label, bytesDownloaded: downloaded, bytesTotal: downloaded))
                return true
            } catch is CancellationError {
                // Cancellation must propagate immediately and leave the `.part`
                // intact so a later run can resume it. Never retry.
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                    continue
                }
            }
        }

        if required {
            throw ModelCatalogError.downloadFailed(Self.downloadFailureMessage(label: label, error: lastError))
        }
        return false
    }

    /// Stream an HTTP GET body to `partial` in OS-sized chunks, appending to any
    /// bytes already present (true byte-level resume). Delegates the transfer to
    /// `StreamingFileDownloadDelegate`, which writes each chunk synchronously to
    /// disk so the socket is throttled to disk speed (backpressure) with nothing
    /// buffered in memory — replacing the old per-byte `URLSession.AsyncBytes`
    /// loop that issued one async step per byte.
    ///
    /// Resume/restart/404/416 semantics and the `onChunk(bytesOnDisk)` progress
    /// contract are documented on the delegate. Cancellation propagates promptly
    /// (`task.cancel()` via the cancellation handler) and leaves a resumable
    /// `.part`.
    private func streamDownload(
        from url: URL,
        to partial: URL,
        label: String,
        required: Bool,
        onChunk: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> Bool {
        let existingBytes = fileSize(partial)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Model shards are multi-GB files. A short request timeout causes
        // legitimate downloads to fail; the streamed transfer keeps the
        // connection alive across the whole download.
        request.timeoutInterval = 6 * 60 * 60
        if existingBytes > 0 {
            request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        }

        let delegate = StreamingFileDownloadDelegate(
            partial: partial,
            existingBytes: existingBytes,
            label: label,
            onChunk: onChunk
        )
        let task = urlSession.dataTask(with: request)
        task.delegate = delegate

        let outcome = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<StreamingFileDownloadDelegate.Outcome, Error>) in
                delegate.attach(cont)
                task.resume()
            }
        } onCancel: {
            // Leaves the bytes already written durably in `.part` for resume.
            task.cancel()
        }

        switch outcome {
        case .notFound(let status):
            try? FileManager.default.removeItem(at: partial)
            if required {
                throw ModelCatalogError.downloadFailed("\(label): HTTP \(status)")
            }
            return false
        case .completeBeyondRange:
            // The `.part` already holds the whole object; the caller's SHA/size
            // check promotes it (or deletes + restarts a corrupt/oversized one).
            onChunk?(existingBytes)
            return true
        case .success:
            return true
        }
    }

    private static func downloadFailureMessage(label: String, error: Error?) -> String {
        guard let error else { return "\(label): unknown error" }
        if case .downloadFailed(let detail) = error as? ModelCatalogError {
            return detail.hasPrefix("\(label):") ? detail : "\(label): \(detail)"
        }
        return "\(label): \(error.localizedDescription)"
    }

    internal func writeMainRef(for modelID: String) throws {
        let modelDir = Self.cacheModelDirectory(for: modelID)
        let refsDir = modelDir.appendingPathComponent("refs")
        try FileManager.default.createDirectory(at: refsDir, withIntermediateDirectories: true)
        try "local".write(
            to: refsDir.appendingPathComponent("main"),
            atomically: true,
            encoding: .utf8
        )
    }

    internal func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    internal static func publishStagedSnapshot(_ stagingDir: URL, to cacheDir: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: cacheDir.path) {
            _ = try fm.replaceItemAt(cacheDir, withItemAt: stagingDir)
        } else {
            try fm.moveItem(at: stagingDir, to: cacheDir)
        }
    }

    private static func sha256Hex(of url: URL) -> String? {
        // Use WeightHasher.hashSingleFile which handles the NSFileProtection
        // fallback for files moved from URLSession temp locations.
        guard let digest = WeightHasher.hashSingleFile(at: url) else { return nil }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256HexForVerification(of url: URL) -> String {
        sha256HexForVerification(of: url, hasher: sha256Hex)
    }

    static func sha256HexForVerification(of url: URL, hasher: (URL) -> String?) -> String {
        hasher(url) ?? "<unreadable>"
    }

}
