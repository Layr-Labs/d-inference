import Crypto
import Foundation
import Testing
@testable import ProviderCore
import ProviderCoreFoundation

// MARK: - URLProtocol that serves manifest files and records requested paths

private final class PrefetchURLProtocol: URLProtocol, @unchecked Sendable {
    /// path (relative to host, e.g. "/v2/prefix/config.json") -> bytes
    nonisolated(unsafe) static var files: [String: Data] = [:]
    /// records every path the downloader actually requested.
    nonisolated(unsafe) static var requestedPaths: [String] = []
    /// records the `Range` header value for every request (nil when absent), in
    /// request order, so a test can prove the resume retry sent `bytes=N-`.
    nonisolated(unsafe) static var rangeHeaders: [(path: String, range: String?)] = []
    /// paths that should FAIL with a transport error (simulating a network
    /// drop). Used by the interrupt/resume test to abort mid-prefetch.
    nonisolated(unsafe) static var failPaths: Set<String> = []
    /// If set, only the FIRST `dropAfterBytes` bytes of a matching path are
    /// delivered before the connection is dropped (true mid-stream interrupt).
    /// Applies to the bytes of THIS response (i.e. measured from the response's
    /// first delivered byte, after any Range offset is applied), and fires on
    /// every matching request unless the path is also in `dropOnce`.
    nonisolated(unsafe) static var dropAfterBytes: [String: Int] = [:]
    /// Paths in this set are dropped (per `dropAfterBytes`) only on their FIRST
    /// request; every subsequent request for the same path is served fully. Used
    /// to exercise true intra-file byte resume: drop once mid-stream, then honor
    /// the `Range` retry and append the remainder.
    nonisolated(unsafe) static var dropOnce: Set<String> = []
    /// Per-path count of how many times each path has been dropped, so `dropOnce`
    /// can stop dropping after the first interrupt.
    nonisolated(unsafe) static var droppedCount: [String: Int] = [:]
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        files = [:]; requestedPaths = []; failPaths = []; rangeHeaders = []
        dropAfterBytes = [:]; dropOnce = []; droppedCount = [:]
        lock.unlock()
    }

    static func record(_ path: String, range: String?) {
        lock.lock(); requestedPaths.append(path); rangeHeaders.append((path, range)); lock.unlock()
    }

    static func fetchedPaths() -> [String] {
        lock.lock(); defer { lock.unlock() }; return requestedPaths
    }

    /// All recorded `Range` headers (in request order), filtered to a path.
    static func rangeHeaders(for path: String) -> [String?] {
        lock.lock(); defer { lock.unlock() }
        return rangeHeaders.filter { $0.path == path }.map { $0.range }
    }

    /// Clear only the request log (keep `files`), so a second prefetch round can
    /// assert exactly which paths IT touched.
    static func clearRequested() {
        lock.lock(); requestedPaths = []; rangeHeaders = []; lock.unlock()
    }

    static func setFailPaths(_ paths: Set<String>) {
        lock.lock(); failPaths = paths; lock.unlock()
    }

    private static func shouldFail(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return failPaths.contains(path)
    }

    /// Returns the byte offset to drop at for this request, or nil to serve the
    /// path fully. Honors `dropOnce`: a one-shot path is dropped only on its
    /// first request, then served fully thereafter.
    private static func dropBytes(_ path: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let drop = dropAfterBytes[path] else { return nil }
        if dropOnce.contains(path), (droppedCount[path] ?? 0) > 0 {
            return nil
        }
        return drop
    }

    /// Record that a path was actually dropped mid-stream (consumes the
    /// one-shot budget for `dropOnce` paths).
    private static func recordDrop(_ path: String) {
        lock.lock(); droppedCount[path] = (droppedCount[path] ?? 0) + 1; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let path = url.path
        Self.record(path, range: request.value(forHTTPHeaderField: "Range"))
        // Simulated network drop: fail the request with a transport-level error
        // exactly the way URLSession surfaces a dropped connection.
        if Self.shouldFail(path) {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        guard let body = Self.files[path] else {
            let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        // Honor Range for resume correctness (downloadFile sends bytes=N-).
        var status = 200
        var data = body
        var headers = ["Content-Length": "\(body.count)"]
        if let range = request.value(forHTTPHeaderField: "Range"),
           range.hasPrefix("bytes="), range.hasSuffix("-"),
           let start = Int(range.dropFirst("bytes=".count).dropLast()), start <= body.count {
            data = Data(body.dropFirst(start))
            status = 206
            headers["Content-Range"] = "bytes \(start)-\(body.count - 1)/\(body.count)"
            headers["Content-Length"] = "\(data.count)"
        }
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        // True mid-stream interrupt: deliver a prefix of the body, then drop the
        // connection so the transfer aborts partway through. The failure is
        // delivered on a LATER runloop tick (not synchronously after didLoad) so
        // the URL loading system flushes the delivered prefix to the consumer
        // BEFORE surfacing the error — faithfully modeling a real connection drop
        // where bytes already received stay received. (Delivering load+fail in the
        // same tick causes URLSession.bytes / dataDelegate to drop the buffered
        // prefix, which a real network never does.)
        if let drop = Self.dropBytes(path), drop < data.count {
            Self.recordDrop(path)
            client?.urlProtocol(self, didLoad: data.prefix(drop))
            let client = self.client
            let me = self
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                client?.urlProtocol(me, didFailWithError: URLError(.networkConnectionLost))
            }
            return
        }
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Thread-safe latest-progress holder for capturing `onByteProgress` callbacks.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done: Int64 = 0
    private var total: Int64 = 0
    func set(done: Int64, total: Int64) {
        lock.lock(); self.done = done; self.total = total; lock.unlock()
    }
    func get() -> (Int64, Int64) {
        lock.lock(); defer { lock.unlock() }; return (done, total)
    }
}

private func sha256Hex(_ data: Data) -> String {
    var hasher = SHA256()
    hasher.update(data: data)
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

@Suite("ModelDownloader.prefetch (resume + verify)", .serialized)
struct ModelPrefetchDownloaderTests {

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PrefetchURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test("prefetch downloads, verifies aggregate, and publishes the snapshot")
    func prefetchFullSuccess() async throws {
        PrefetchURLProtocol.reset()
        let modelID = "test-org/prefetch-full-\(UUID().uuidString)"
        let prefix = "v2/prefetch-full/v1"
        let configBytes = Data("a fake config".utf8)
        let weightBytes = Data("a fake weight payload".utf8)

        let files = [
            ManifestFile(path: "config.json", sizeBytes: Int64(configBytes.count), sha256: sha256Hex(configBytes), role: "config"),
            ManifestFile(path: "model.safetensors", sizeBytes: Int64(weightBytes.count), sha256: sha256Hex(weightBytes), role: "weight"),
        ]
        let cacheDir = ModelDownloader.cacheSnapshotDirectory(for: modelID)
        let modelDir = ModelDownloader.cacheModelDirectory(for: modelID)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        // Aggregate hash over staged files, sorted by relative path (the same
        // rule prefetch uses). hashFilesWithRelativeKey is the production hasher.
        let aggregate = aggregateHash(files: [
            ("config.json", configBytes),
            ("model.safetensors", weightBytes),
        ])
        let manifest = ModelManifest(
            schemaVersion: 1, modelID: modelID, version: "v1", r2Prefix: prefix,
            aggregateSHA256: aggregate, totalSizeBytes: Int64(configBytes.count + weightBytes.count),
            fileCount: 2, files: files, createdAt: Date(timeIntervalSince1970: 0)
        )
        PrefetchURLProtocol.files = [
            "/\(prefix)/config.json": configBytes,
            "/\(prefix)/model.safetensors": weightBytes,
        ]

        let downloader = ModelDownloader(r2CDNURL: "https://cdn.example.test", urlSession: makeSession())
        let model = CatalogModel(id: modelID, s3Name: "unused", displayName: "Full", sizeGb: 0.001,
                                 r2Prefix: prefix, aggregateSHA256: aggregate)

        let lastProgress = ProgressBox()
        try await downloader.prefetch(model: model, manifest: manifest) { done, total in
            lastProgress.set(done: done, total: total)
        }

        // Snapshot published with both files + refs/main.
        #expect(try Data(contentsOf: cacheDir.appendingPathComponent("config.json")) == configBytes)
        #expect(try Data(contentsOf: cacheDir.appendingPathComponent("model.safetensors")) == weightBytes)
        let mainRef = modelDir.appendingPathComponent("refs/main")
        #expect(try String(contentsOf: mainRef, encoding: .utf8) == "local")
        let (lastDone, lastTotal) = lastProgress.get()
        #expect(lastDone == lastTotal && lastTotal == manifest.totalSizeBytes)
    }

    @Test("prefetch resumes: already-valid files are skipped, only missing files fetched")
    func prefetchResumesSkipsValidFiles() async throws {
        PrefetchURLProtocol.reset()
        let modelID = "test-org/prefetch-resume-\(UUID().uuidString)"
        let prefix = "v2/prefetch-resume/v1"
        let configBytes = Data("config that is already present".utf8)
        let weightBytes = Data("weight that still needs fetching".utf8)

        let files = [
            ManifestFile(path: "config.json", sizeBytes: Int64(configBytes.count), sha256: sha256Hex(configBytes), role: "config"),
            ManifestFile(path: "model.safetensors", sizeBytes: Int64(weightBytes.count), sha256: sha256Hex(weightBytes), role: "weight"),
        ]
        let aggregate = aggregateHash(files: [
            ("config.json", configBytes),
            ("model.safetensors", weightBytes),
        ])
        let manifest = ModelManifest(
            schemaVersion: 1, modelID: modelID, version: "v1", r2Prefix: prefix,
            aggregateSHA256: aggregate, totalSizeBytes: Int64(configBytes.count + weightBytes.count),
            fileCount: 2, files: files, createdAt: Date(timeIntervalSince1970: 0)
        )
        PrefetchURLProtocol.files = [
            "/\(prefix)/config.json": configBytes,
            "/\(prefix)/model.safetensors": weightBytes,
        ]

        let cacheDir = ModelDownloader.cacheSnapshotDirectory(for: modelID)
        let snapshotsDir = cacheDir.deletingLastPathComponent()
        let modelDir = ModelDownloader.cacheModelDirectory(for: modelID)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        // Pre-seed the STABLE staging dir with a VALID config.json (simulating an
        // interrupted prior prefetch that already got config.json).
        let stagingName = ".prefetch-staging-" + prefix.replacingOccurrences(of: "/", with: "__")
        let stagingDir = snapshotsDir.appendingPathComponent(stagingName, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try configBytes.write(to: stagingDir.appendingPathComponent("config.json"))

        let downloader = ModelDownloader(r2CDNURL: "https://cdn.example.test", urlSession: makeSession())
        let model = CatalogModel(id: modelID, s3Name: "unused", displayName: "Resume", sizeGb: 0.001,
                                 r2Prefix: prefix, aggregateSHA256: aggregate)

        try await downloader.prefetch(model: model, manifest: manifest)

        // Only the MISSING weight file was fetched; the valid config was skipped.
        let fetched = PrefetchURLProtocol.fetchedPaths()
        #expect(fetched.contains("/\(prefix)/model.safetensors"))
        #expect(!fetched.contains("/\(prefix)/config.json"))
        // Final snapshot is complete + correct.
        #expect(try Data(contentsOf: cacheDir.appendingPathComponent("config.json")) == configBytes)
        #expect(try Data(contentsOf: cacheDir.appendingPathComponent("model.safetensors")) == weightBytes)
    }

    @Test("prefetch interrupted mid-download resumes from disk and never re-fetches completed files")
    func prefetchInterruptThenResume() async throws {
        // DAR-136 "never restart from zero": a network drop partway through a
        // prefetch must (a) leave already-downloaded files on disk in staging,
        // (b) NOT delete staging, and (c) on retry skip every already-valid file
        // and fetch only what is missing, then publish + clean up.
        PrefetchURLProtocol.reset()
        let modelID = "test-org/prefetch-interrupt-\(UUID().uuidString)"
        let prefix = "v2/prefetch-interrupt/v1"

        // N = 4 files; the prefetch loop fetches them in manifest order. We
        // interrupt at file index K = 2 (0-based: files[2]) so files[0..1] land
        // and files[2..3] do not.
        let names = ["a-config.json", "b-tokenizer.json", "c-shard0.safetensors", "d-shard1.safetensors"]
        var files: [ManifestFile] = []
        var served: [String: Data] = [:]
        var pairs: [(String, Data)] = []
        for name in names {
            let bytes = Data("payload-for-\(name)-\(UUID().uuidString)".utf8)
            files.append(ManifestFile(path: name, sizeBytes: Int64(bytes.count), sha256: sha256Hex(bytes), role: "weight"))
            served["/\(prefix)/\(name)"] = bytes
            pairs.append((name, bytes))
        }
        let aggregate = aggregateHash(files: pairs)
        let manifest = ModelManifest(
            schemaVersion: 1, modelID: modelID, version: "v1", r2Prefix: prefix,
            aggregateSHA256: aggregate, totalSizeBytes: Int64(pairs.reduce(0) { $0 + $1.1.count }),
            fileCount: files.count, files: files, createdAt: Date(timeIntervalSince1970: 0)
        )
        PrefetchURLProtocol.files = served

        let cacheDir = ModelDownloader.cacheSnapshotDirectory(for: modelID)
        let snapshotsDir = cacheDir.deletingLastPathComponent()
        let modelDir = ModelDownloader.cacheModelDirectory(for: modelID)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        // Production staging-dir naming rule (keyed by r2Prefix).
        let stagingName = ".prefetch-staging-" + prefix.replacingOccurrences(of: "/", with: "__")
        let stagingDir = snapshotsDir.appendingPathComponent(stagingName, isDirectory: true)

        let downloader = ModelDownloader(r2CDNURL: "https://cdn.example.test", urlSession: makeSession())
        let model = CatalogModel(id: modelID, s3Name: "unused", displayName: "Interrupt", sizeGb: 0.001,
                                 r2Prefix: prefix, aggregateSHA256: aggregate)

        // ---- Attempt 1: drop the connection on file index 2 (c-shard0) and
        // everything after it. files[0..1] should land in staging; the call
        // throws; staging survives. ----
        PrefetchURLProtocol.setFailPaths([
            "/\(prefix)/\(names[2])",
            "/\(prefix)/\(names[3])",
        ])

        var attempt1Threw = false
        do {
            try await downloader.prefetch(model: model, manifest: manifest)
        } catch {
            attempt1Threw = true
        }
        #expect(attempt1Threw)

        // Staging dir was NOT deleted (resume-on-disk guarantee).
        #expect(FileManager.default.fileExists(atPath: stagingDir.path))
        // Nothing was published to the live snapshot dir.
        #expect(!FileManager.default.fileExists(atPath: cacheDir.path))

        // Files 0..1 are on disk in staging AND pass fileMatches (size + SHA).
        for i in 0..<2 {
            let staged = stagingDir.appendingPathComponent(names[i])
            #expect(FileManager.default.fileExists(atPath: staged.path), "expected \(names[i]) to survive the interrupt")
            #expect(ModelDownloader.fileMatches(staged, size: files[i].sizeBytes, sha256: files[i].sha256),
                    "\(names[i]) should be a complete, valid staged file")
        }
        // Files 2..3 are NOT present (interrupted before/at them).
        for i in 2..<4 {
            let staged = stagingDir.appendingPathComponent(names[i])
            #expect(!FileManager.default.fileExists(atPath: staged.path), "\(names[i]) should not exist after the drop")
        }

        // ---- Attempt 2 (resume): the network is healthy again. The already-valid
        // files MUST be skipped (never requested); only the missing ones fetched.
        // We assert the skip by clearing the request log and checking that round 2
        // touched ONLY the missing paths. ----
        PrefetchURLProtocol.setFailPaths([])
        PrefetchURLProtocol.clearRequested()

        try await downloader.prefetch(model: model, manifest: manifest)

        let round2 = Set(PrefetchURLProtocol.fetchedPaths())
        // Already-valid files were skipped (proving resume never restarts work).
        #expect(!round2.contains("/\(prefix)/\(names[0])"), "config should NOT be re-fetched on resume")
        #expect(!round2.contains("/\(prefix)/\(names[1])"), "tokenizer should NOT be re-fetched on resume")
        // The missing files were fetched.
        #expect(round2.contains("/\(prefix)/\(names[2])"))
        #expect(round2.contains("/\(prefix)/\(names[3])"))

        // The aggregate verified and the snapshot was published to the live dir.
        for (i, name) in names.enumerated() {
            let published = cacheDir.appendingPathComponent(name)
            #expect(try Data(contentsOf: published) == served["/\(prefix)/\(name)"], "published \(name) must match served bytes")
            _ = i
        }
        // refs/main points at the local snapshot so ModelScanner discovers it.
        let mainRef = modelDir.appendingPathComponent("refs/main")
        #expect(try String(contentsOf: mainRef, encoding: .utf8) == "local")
        // Staging was cleaned up after a successful publish.
        #expect(!FileManager.default.fileExists(atPath: stagingDir.path), "staging should be removed after publish")
    }

    @Test("prefetch resumes after a mid-stream connection drop without re-fetching completed files")
    func prefetchResumesPartialFile() async throws {
        // Variant of the interrupt test where the connection drops MID-STREAM
        // (partial bytes delivered) rather than before the file starts. A
        // half-transferred file must NEVER be promoted as valid (size + per-file
        // SHA reject the truncation), so the prefetch throws; the earlier,
        // already-complete file survives in staging; and on retry that completed
        // file is skipped while the dropped one is re-fetched to completion.
        PrefetchURLProtocol.reset()
        let modelID = "test-org/prefetch-partial-\(UUID().uuidString)"
        let prefix = "v2/prefetch-partial/v1"
        let names = ["a-config.json", "b-weights.safetensors"]
        // Sizes are deliberately asymmetric: a tiny config and a large weight
        // file. With real byte-level resume, each dropped attempt APPENDS the
        // received prefix to `.part`, so the weight must be large enough that the
        // 3 in-call retries (each dropping ~1500 bytes) cannot finish it — the
        // prefetch still throws on attempt 1, but `.part` has made real progress.
        let sizes = [64, 16384]
        var files: [ManifestFile] = []
        var served: [String: Data] = [:]
        var pairs: [(String, Data)] = []
        for (idx, name) in names.enumerated() {
            // Large enough that a prefix is a meaningful partial.
            let bytes = Data((0..<sizes[idx]).map { UInt8(($0 &* 31 &+ name.count) & 0xFF) })
            files.append(ManifestFile(path: name, sizeBytes: Int64(bytes.count), sha256: sha256Hex(bytes), role: "weight"))
            served["/\(prefix)/\(name)"] = bytes
            pairs.append((name, bytes))
        }
        let aggregate = aggregateHash(files: pairs)
        let manifest = ModelManifest(
            schemaVersion: 1, modelID: modelID, version: "v1", r2Prefix: prefix,
            aggregateSHA256: aggregate, totalSizeBytes: Int64(pairs.reduce(0) { $0 + $1.1.count }),
            fileCount: files.count, files: files, createdAt: Date(timeIntervalSince1970: 0)
        )
        PrefetchURLProtocol.files = served

        let cacheDir = ModelDownloader.cacheSnapshotDirectory(for: modelID)
        let modelDir = ModelDownloader.cacheModelDirectory(for: modelID)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        let downloader = ModelDownloader(r2CDNURL: "https://cdn.example.test", urlSession: makeSession())
        let model = CatalogModel(id: modelID, s3Name: "unused", displayName: "Partial", sizeGb: 0.001,
                                 r2Prefix: prefix, aggregateSHA256: aggregate)

        // Attempt 1: config lands fine; the large weight drops after ~1500 bytes
        // on every attempt. With byte resume each retry APPENDS its prefix, but
        // 3 × ~1500 « 16384, so the weight cannot complete and prefetch throws.
        let stagingName = ".prefetch-staging-" + prefix.replacingOccurrences(of: "/", with: "__")
        let stagingDir = cacheDir.deletingLastPathComponent().appendingPathComponent(stagingName, isDirectory: true)
        let weightPart = stagingDir.appendingPathComponent(names[1]).appendingPathExtension("part")
        PrefetchURLProtocol.dropAfterBytes = ["/\(prefix)/\(names[1])": 1500]

        var threw = false
        do { try await downloader.prefetch(model: model, manifest: manifest) } catch { threw = true }
        #expect(threw)
        // config completed and survives; snapshot not published.
        #expect(ModelDownloader.fileMatches(stagingDir.appendingPathComponent(names[0]), size: files[0].sizeBytes, sha256: files[0].sha256))
        #expect(!FileManager.default.fileExists(atPath: cacheDir.path))
        // The dropped weight made real progress on disk and was NOT zeroed: its
        // `.part` holds the appended prefix (proving byte-level resume, not
        // restart-from-zero), but is still short of the full file.
        let partProgress = (try? Data(contentsOf: weightPart))?.count ?? 0
        #expect(partProgress >= 1500, "weight .part must retain appended progress, got \(partProgress)")
        #expect(partProgress < sizes[1], "weight must not be complete yet, got \(partProgress)/\(sizes[1])")

        // Attempt 2: healthy. config skipped, the weight RESUMES from its `.part`
        // (Range request) and completes — never restarting from zero.
        PrefetchURLProtocol.dropAfterBytes = [:]
        PrefetchURLProtocol.clearRequested()
        try await downloader.prefetch(model: model, manifest: manifest)

        let round2 = Set(PrefetchURLProtocol.fetchedPaths())
        #expect(!round2.contains("/\(prefix)/\(names[0])"), "completed config must not be re-fetched")
        #expect(round2.contains("/\(prefix)/\(names[1])"))
        // The resume retry on the weight carried a Range header (append, not restart).
        let weightRanges = PrefetchURLProtocol.rangeHeaders(for: "/\(prefix)/\(names[1])")
        #expect(weightRanges.contains(where: { ($0 ?? "").hasPrefix("bytes=") }),
                "weight resume must send a Range header; got \(weightRanges)")
        #expect(try Data(contentsOf: cacheDir.appendingPathComponent(names[1])) == served["/\(prefix)/\(names[1])"])
        #expect(!FileManager.default.fileExists(atPath: stagingDir.path))
    }

    @Test("intra-file byte resume: a mid-stream drop keeps the prefix on disk and the retry sends a Range header to append, not restart")
    func prefetchIntraFileByteResume() async throws {
        // The core DAR-136 guarantee at BYTE granularity: a single shard that
        // drops mid-stream must NOT restart from zero. The prefix received before
        // the drop must persist in `<dest>.part`, and the retry must send
        // `Range: bytes=<prefix>-` and APPEND the remainder — so a shard that
        // keeps dropping at 90% makes monotonic progress instead of looping.
        PrefetchURLProtocol.reset()
        let modelID = "test-org/prefetch-byteresume-\(UUID().uuidString)"
        let prefix = "v2/prefetch-byteresume/v1"
        // One shard, large enough that the 1500-byte prefix is a meaningful
        // fraction of the whole (so "restart from zero" would be obviously wrong).
        let shardBytes = Data((0..<8192).map { UInt8(($0 &* 131 &+ 7) & 0xFF) })
        let dropAt = 1500
        let shardName = "model.safetensors"
        let shardPath = "/\(prefix)/\(shardName)"
        let files = [
            ManifestFile(path: shardName, sizeBytes: Int64(shardBytes.count), sha256: sha256Hex(shardBytes), role: "weight"),
        ]
        let aggregate = aggregateHash(files: [(shardName, shardBytes)])
        let manifest = ModelManifest(
            schemaVersion: 1, modelID: modelID, version: "v1", r2Prefix: prefix,
            aggregateSHA256: aggregate, totalSizeBytes: Int64(shardBytes.count),
            fileCount: 1, files: files, createdAt: Date(timeIntervalSince1970: 0)
        )
        PrefetchURLProtocol.files = [shardPath: shardBytes]

        let cacheDir = ModelDownloader.cacheSnapshotDirectory(for: modelID)
        let snapshotsDir = cacheDir.deletingLastPathComponent()
        let modelDir = ModelDownloader.cacheModelDirectory(for: modelID)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        let stagingName = ".prefetch-staging-" + prefix.replacingOccurrences(of: "/", with: "__")
        let stagingDir = snapshotsDir.appendingPathComponent(stagingName, isDirectory: true)
        let partFile = stagingDir.appendingPathComponent(shardName).appendingPathExtension("part")

        let downloader = ModelDownloader(r2CDNURL: "https://cdn.example.test", urlSession: makeSession())
        let model = CatalogModel(id: modelID, s3Name: "unused", displayName: "ByteResume", sizeGb: 0.001,
                                 r2Prefix: prefix, aggregateSHA256: aggregate)

        // ---- Attempt 1: drop ONCE at byte 1500 mid-stream. The single shard's
        // 3 retries within downloadFile will each fail (dropOnce keeps the first
        // request dropping until the .part exists, but the in-process retries
        // happen within the SAME prefetch call). To force the throw and inspect
        // the .part, mark the path dropOnce so only the very first request drops;
        // the in-call retry then RESUMES and completes. We therefore split the
        // assertion: drive a fresh prefetch where the path drops on attempt 1 and
        // resumes on attempt 2 WITHIN the same call, and verify (a) the resume
        // retry sent a Range header and (b) the file completed + published. ----
        PrefetchURLProtocol.dropAfterBytes = [shardPath: dropAt]
        PrefetchURLProtocol.dropOnce = [shardPath]

        try await downloader.prefetch(model: model, manifest: manifest)

        // The shard was requested at least twice: the dropped first attempt and
        // the resuming retry.
        let ranges = PrefetchURLProtocol.rangeHeaders(for: shardPath)
        #expect(ranges.count >= 2, "expected an initial request plus a resume retry, got \(ranges.count)")
        // First request had no Range (fresh download from byte 0).
        #expect(ranges.first ?? nil == nil, "first request should not carry a Range header")
        // A later request resumed from exactly the dropped offset — proving
        // intra-file byte resume (append), not a restart from zero.
        #expect(ranges.contains("bytes=\(dropAt)-"),
                "resume retry must send Range bytes=\(dropAt)-; got \(ranges)")
        // The `.part` was consumed (promoted to final) on success.
        #expect(!FileManager.default.fileExists(atPath: partFile.path))
        // The published snapshot has the complete, correct shard.
        #expect(try Data(contentsOf: cacheDir.appendingPathComponent(shardName)) == shardBytes)
    }

    @Test("a mid-stream drop persists the received prefix in .part (resumable, not zeroed)")
    func midStreamDropRetainsPartPrefix() async throws {
        // Lower-level proof that the prefix is durable on disk at the moment of a
        // drop: drive a single-file download whose connection ALWAYS drops ~1500
        // bytes into each response, then inspect the `.part` directly. The
        // transfer fails (3 in-call retries, each dropping again), but every byte
        // received before a drop is APPENDED and persisted — so `.part` holds the
        // accumulated prefix (never empty/zeroed) and a future run resumes from it
        // instead of restarting from zero. The file is large enough that 3 partial
        // appends cannot complete it.
        PrefetchURLProtocol.reset()
        let modelID = "test-org/prefetch-partprefix-\(UUID().uuidString)"
        let prefix = "v2/prefetch-partprefix/v1"
        let shardBytes = Data((0..<32768).map { UInt8(($0 &* 17 &+ 3) & 0xFF) })
        let dropAt = 1500
        let shardName = "model.safetensors"
        let shardPath = "/\(prefix)/\(shardName)"
        let files = [
            ManifestFile(path: shardName, sizeBytes: Int64(shardBytes.count), sha256: sha256Hex(shardBytes), role: "weight"),
        ]
        let manifest = ModelManifest(
            schemaVersion: 1, modelID: modelID, version: "v1", r2Prefix: prefix,
            aggregateSHA256: aggregateHash(files: [(shardName, shardBytes)]),
            totalSizeBytes: Int64(shardBytes.count),
            fileCount: 1, files: files, createdAt: Date(timeIntervalSince1970: 0)
        )
        PrefetchURLProtocol.files = [shardPath: shardBytes]

        let cacheDir = ModelDownloader.cacheSnapshotDirectory(for: modelID)
        let snapshotsDir = cacheDir.deletingLastPathComponent()
        let modelDir = ModelDownloader.cacheModelDirectory(for: modelID)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        let stagingName = ".prefetch-staging-" + prefix.replacingOccurrences(of: "/", with: "__")
        let stagingDir = snapshotsDir.appendingPathComponent(stagingName, isDirectory: true)
        let partFile = stagingDir.appendingPathComponent(shardName).appendingPathExtension("part")

        let downloader = ModelDownloader(r2CDNURL: "https://cdn.example.test", urlSession: makeSession())
        let model = CatalogModel(id: modelID, s3Name: "unused", displayName: "PartPrefix", sizeGb: 0.001,
                                 r2Prefix: prefix, aggregateSHA256: manifest.aggregateSHA256)

        // Drop on EVERY attempt → the 3 in-call retries exhaust and prefetch throws.
        PrefetchURLProtocol.dropAfterBytes = [shardPath: dropAt]

        var threw = false
        do { try await downloader.prefetch(model: model, manifest: manifest) } catch { threw = true }
        #expect(threw)

        // The `.part` survives and holds the accumulated prefix — durable, not
        // zeroed — proving received bytes persist across drops for resume. With
        // byte-level resume each dropped retry appends its prefix, so `.part`
        // holds at least one drop's worth and is a correct PREFIX of the file,
        // but is not complete (3 partial appends < 32768).
        #expect(FileManager.default.fileExists(atPath: partFile.path), ".part must survive a drop for resume")
        let onDisk = try Data(contentsOf: partFile)
        #expect(onDisk.count >= dropAt, "expected at least \(dropAt) durable prefix bytes, got \(onDisk.count)")
        #expect(onDisk.count < shardBytes.count, "weight must not be complete after repeated drops, got \(onDisk.count)/\(shardBytes.count)")
        #expect(onDisk == shardBytes.prefix(onDisk.count), "the persisted bytes must be a correct prefix of the served file")
    }

    @Test("aggregate-mismatch on internally-valid files clears staging so a corrected manifest re-downloads")
    func aggregateMismatchClearsStagingForRecovery() async throws {
        // Fix 2: when every per-file SHA is valid but the manifest's aggregate is
        // WRONG, prefetch must NOT leave staging behind. Otherwise `fileMatches`
        // would skip all files on every retry and re-fail the aggregate forever
        // (a permanent poison state). The aggregate-mismatch path — and ONLY that
        // path — clears staging so a corrected aggregate re-downloads cleanly.
        PrefetchURLProtocol.reset()
        let modelID = "test-org/prefetch-aggpoison-\(UUID().uuidString)"
        let prefix = "v2/prefetch-aggpoison/v1"
        let configBytes = Data("a valid config".utf8)
        let weightBytes = Data("a valid weight payload".utf8)
        let files = [
            ManifestFile(path: "config.json", sizeBytes: Int64(configBytes.count), sha256: sha256Hex(configBytes), role: "config"),
            ManifestFile(path: "model.safetensors", sizeBytes: Int64(weightBytes.count), sha256: sha256Hex(weightBytes), role: "weight"),
        ]
        // The CORRECT aggregate over the staged files.
        let correctAggregate = aggregateHash(files: [
            ("config.json", configBytes),
            ("model.safetensors", weightBytes),
        ])
        // A WRONG aggregate while every per-file SHA stays valid (manifest/aggregate
        // is corrupt, the bytes are fine).
        let wrongAggregate = String(repeating: "e", count: 64)
        #expect(wrongAggregate != correctAggregate)

        let badManifest = ModelManifest(
            schemaVersion: 1, modelID: modelID, version: "v1", r2Prefix: prefix,
            aggregateSHA256: wrongAggregate, totalSizeBytes: Int64(configBytes.count + weightBytes.count),
            fileCount: 2, files: files, createdAt: Date(timeIntervalSince1970: 0)
        )
        PrefetchURLProtocol.files = [
            "/\(prefix)/config.json": configBytes,
            "/\(prefix)/model.safetensors": weightBytes,
        ]

        let cacheDir = ModelDownloader.cacheSnapshotDirectory(for: modelID)
        let snapshotsDir = cacheDir.deletingLastPathComponent()
        let modelDir = ModelDownloader.cacheModelDirectory(for: modelID)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        let stagingName = ".prefetch-staging-" + prefix.replacingOccurrences(of: "/", with: "__")
        let stagingDir = snapshotsDir.appendingPathComponent(stagingName, isDirectory: true)

        let downloader = ModelDownloader(r2CDNURL: "https://cdn.example.test", urlSession: makeSession())
        let badModel = CatalogModel(id: modelID, s3Name: "unused", displayName: "AggPoison", sizeGb: 0.001,
                                    r2Prefix: prefix, aggregateSHA256: wrongAggregate)

        // ---- Attempt 1: all per-file SHAs pass, the aggregate fails. Must throw
        // AND clear staging (so the next, corrected attempt does not skip
        // everything and re-fail forever). ----
        await #expect(throws: ModelCatalogError.self) {
            try await downloader.prefetch(model: badModel, manifest: badManifest)
        }
        #expect(!FileManager.default.fileExists(atPath: stagingDir.path),
                "staging must be cleared after an aggregate-hash mismatch")
        #expect(!FileManager.default.fileExists(atPath: cacheDir.path), "nothing must be published")

        // ---- Attempt 2: a CORRECTED manifest (right aggregate). Because staging
        // was cleared, the files re-download and the prefetch succeeds. ----
        let goodManifest = ModelManifest(
            schemaVersion: 1, modelID: modelID, version: "v1", r2Prefix: prefix,
            aggregateSHA256: correctAggregate, totalSizeBytes: Int64(configBytes.count + weightBytes.count),
            fileCount: 2, files: files, createdAt: Date(timeIntervalSince1970: 0)
        )
        let goodModel = CatalogModel(id: modelID, s3Name: "unused", displayName: "AggFixed", sizeGb: 0.001,
                                     r2Prefix: prefix, aggregateSHA256: correctAggregate)

        try await downloader.prefetch(model: goodModel, manifest: goodManifest)
        #expect(try Data(contentsOf: cacheDir.appendingPathComponent("config.json")) == configBytes)
        #expect(try Data(contentsOf: cacheDir.appendingPathComponent("model.safetensors")) == weightBytes)
        #expect(!FileManager.default.fileExists(atPath: stagingDir.path), "staging removed after a successful publish")
    }

    @Test("disk capacity pre-check counts only the bytes still to fetch on a resume")
    func capacityPreCheckCountsRemainingBytesOnResume() async throws {
        // A resumed prefetch must size its capacity pre-check to the REMAINING
        // (not-yet-valid) files, not the full model. Otherwise a resume that has
        // ample room for what's left would be spuriously rejected for lacking
        // room equal to the whole model.
        //
        // Direct check of the pure remaining-bytes computation that the capacity
        // pre-check feeds: when most files are already valid, only the missing
        // file's size is required.
        let sizes: [Int64] = [10_000_000_000, 2_000_000_000, 500_000_000] // 12.5 GB total
        // First two already staged+valid; only the third (500 MB) remains.
        let remaining = ModelDownloader.remainingBytesToFetch(
            sizes: sizes,
            alreadyValid: [true, true, false]
        )
        #expect(remaining == 500_000_000) // NOT the 12.5 GB total
        // A fresh prefetch (nothing valid) requires the full total.
        let fresh = ModelDownloader.remainingBytesToFetch(
            sizes: sizes,
            alreadyValid: [false, false, false]
        )
        #expect(fresh == 12_500_000_000)
        // A fully-staged resume requires zero new bytes (capacity check is a noop).
        let none = ModelDownloader.remainingBytesToFetch(
            sizes: sizes,
            alreadyValid: [true, true, true]
        )
        #expect(none == 0)

        // Codex P2 fix: bytes already saved in a `.part` must be credited so a
        // near-complete resume of a big shard isn't charged the whole shard. Here
        // the 10 GB shard already has 9.5 GB in its `.part`, the 2 GB file is fully
        // valid, and the 0.5 GB file is untouched → only 0.5 GB (shard remainder)
        // + 0.5 GB = 1.0 GB remains, NOT 10.5 GB.
        let withPart = ModelDownloader.remainingBytesToFetch(
            sizes: sizes,
            alreadyValid: [false, true, false],
            partBytes: [9_500_000_000, 0, 0]
        )
        #expect(withPart == 1_000_000_000)
        // A stale `.part` longer than the file can't drive the requirement below 0.
        let overlong = ModelDownloader.remainingBytesToFetch(
            sizes: [1_000], alreadyValid: [false], partBytes: [5_000]
        )
        #expect(overlong == 0)

        // End-to-end: pre-stage the large file as valid, leave a tiny file to
        // fetch. The capacity pre-check (now sized to remaining bytes) must NOT
        // reject the resume, and prefetch completes + publishes.
        PrefetchURLProtocol.reset()
        let modelID = "test-org/prefetch-capacity-\(UUID().uuidString)"
        let prefix = "v2/prefetch-capacity/v1"
        // "Large" relative to the tiny remaining file; both small in absolute
        // terms so the real volume always has room (we're proving the check is
        // sized to REMAINING bytes, which is what the resume path relies on).
        let bigBytes = Data((0..<200_000).map { UInt8(($0 &* 7) & 0xFF) })
        let smallBytes = Data("small remaining file".utf8)
        let files = [
            ManifestFile(path: "big.safetensors", sizeBytes: Int64(bigBytes.count), sha256: sha256Hex(bigBytes), role: "weight"),
            ManifestFile(path: "small.json", sizeBytes: Int64(smallBytes.count), sha256: sha256Hex(smallBytes), role: "config"),
        ]
        let aggregate = aggregateHash(files: [
            ("big.safetensors", bigBytes),
            ("small.json", smallBytes),
        ])
        let manifest = ModelManifest(
            schemaVersion: 1, modelID: modelID, version: "v1", r2Prefix: prefix,
            aggregateSHA256: aggregate, totalSizeBytes: Int64(bigBytes.count + smallBytes.count),
            fileCount: 2, files: files, createdAt: Date(timeIntervalSince1970: 0)
        )
        PrefetchURLProtocol.files = [
            "/\(prefix)/big.safetensors": bigBytes,
            "/\(prefix)/small.json": smallBytes,
        ]

        let cacheDir = ModelDownloader.cacheSnapshotDirectory(for: modelID)
        let snapshotsDir = cacheDir.deletingLastPathComponent()
        let modelDir = ModelDownloader.cacheModelDirectory(for: modelID)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        // Pre-seed staging with the VALID big file (interrupted prior prefetch).
        let stagingName = ".prefetch-staging-" + prefix.replacingOccurrences(of: "/", with: "__")
        let stagingDir = snapshotsDir.appendingPathComponent(stagingName, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try bigBytes.write(to: stagingDir.appendingPathComponent("big.safetensors"))

        let downloader = ModelDownloader(r2CDNURL: "https://cdn.example.test", urlSession: makeSession())
        let model = CatalogModel(id: modelID, s3Name: "unused", displayName: "Capacity", sizeGb: 0.001,
                                 r2Prefix: prefix, aggregateSHA256: aggregate)

        // Resume succeeds: the capacity pre-check (sized to the small remaining
        // file) passes, only the small file is fetched, and the snapshot publishes.
        try await downloader.prefetch(model: model, manifest: manifest)
        let fetched = PrefetchURLProtocol.fetchedPaths()
        #expect(fetched.contains("/\(prefix)/small.json"))
        #expect(!fetched.contains("/\(prefix)/big.safetensors")) // big was skipped
        #expect(try Data(contentsOf: cacheDir.appendingPathComponent("big.safetensors")) == bigBytes)
        #expect(try Data(contentsOf: cacheDir.appendingPathComponent("small.json")) == smallBytes)
    }

    @Test("foreground download resumes: already-valid staged files are skipped, only missing files fetched")
    func foregroundDownloadResumesFromStaging() async throws {
        // The foreground (serve-time) download path must also resume an interrupted
        // download instead of restarting from zero: a file already staged + valid is
        // skipped and only the missing file is fetched. (Previously the foreground
        // path used a throwaway UUID staging dir and re-downloaded everything.)
        PrefetchURLProtocol.reset()
        let modelID = "test-org/fg-resume-\(UUID().uuidString)"
        let prefix = "v2/fg-resume/v1"
        let bigBytes = Data((0..<300_000).map { UInt8(($0 &* 13) & 0xFF) })
        let smallBytes = Data("foreground remaining file".utf8)
        let files = [
            ManifestFile(path: "model-00001-of-00001.safetensors", sizeBytes: Int64(bigBytes.count), sha256: sha256Hex(bigBytes), role: "weight"),
            ManifestFile(path: "config.json", sizeBytes: Int64(smallBytes.count), sha256: sha256Hex(smallBytes), role: "config"),
        ]
        let aggregate = aggregateHash(files: [
            ("model-00001-of-00001.safetensors", bigBytes),
            ("config.json", smallBytes),
        ])
        let manifest = ModelManifest(
            schemaVersion: 1, modelID: modelID, version: "v1", r2Prefix: prefix,
            aggregateSHA256: aggregate, totalSizeBytes: Int64(bigBytes.count + smallBytes.count),
            fileCount: 2, files: files, createdAt: Date(timeIntervalSince1970: 0)
        )
        // Serve manifest.json the same way the CDN decoder expects (iso8601 dates,
        // explicit snake_case CodingKeys round-trip through manifestDecoder).
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        PrefetchURLProtocol.files = [
            "/\(prefix)/manifest.json": try enc.encode(manifest),
            "/\(prefix)/model-00001-of-00001.safetensors": bigBytes,
            "/\(prefix)/config.json": smallBytes,
        ]

        let cacheDir = ModelDownloader.cacheSnapshotDirectory(for: modelID)
        let snapshotsDir = cacheDir.deletingLastPathComponent()
        let modelDir = ModelDownloader.cacheModelDirectory(for: modelID)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        // Pre-seed the FOREGROUND staging dir with the VALID big file (an
        // interrupted prior foreground download).
        let stagingName = ".local-staging-" + prefix.replacingOccurrences(of: "/", with: "__")
        let stagingDir = snapshotsDir.appendingPathComponent(stagingName, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try bigBytes.write(to: stagingDir.appendingPathComponent("model-00001-of-00001.safetensors"))

        let downloader = ModelDownloader(r2CDNURL: "https://cdn.example.test", urlSession: makeSession())
        let model = CatalogModel(id: modelID, s3Name: "unused", displayName: "FG", sizeGb: 0.001,
                                 r2Prefix: prefix, aggregateSHA256: aggregate)

        try await downloader.download(model: model)

        let fetched = PrefetchURLProtocol.fetchedPaths()
        #expect(fetched.contains("/\(prefix)/config.json")) // missing file fetched
        #expect(!fetched.contains("/\(prefix)/model-00001-of-00001.safetensors")) // staged file skipped
        #expect(try Data(contentsOf: cacheDir.appendingPathComponent("model-00001-of-00001.safetensors")) == bigBytes)
        #expect(try Data(contentsOf: cacheDir.appendingPathComponent("config.json")) == smallBytes)
    }

    @Test("prefetch fails on aggregate hash mismatch and does not publish")
    func prefetchAggregateMismatchFails() async throws {
        PrefetchURLProtocol.reset()
        let modelID = "test-org/prefetch-mismatch-\(UUID().uuidString)"
        let prefix = "v2/prefetch-mismatch/v1"
        let configBytes = Data("config".utf8)
        // Manifest claims a per-file SHA that does NOT match the served bytes →
        // per-file verification fails first, surfacing a download failure.
        let wrongSHA = String(repeating: "0", count: 64)
        let files = [ManifestFile(path: "config.json", sizeBytes: Int64(configBytes.count), sha256: wrongSHA, role: "config")]
        let manifest = ModelManifest(
            schemaVersion: 1, modelID: modelID, version: "v1", r2Prefix: prefix,
            aggregateSHA256: String(repeating: "f", count: 64), totalSizeBytes: Int64(configBytes.count),
            fileCount: 1, files: files, createdAt: Date(timeIntervalSince1970: 0)
        )
        PrefetchURLProtocol.files = ["/\(prefix)/config.json": configBytes]

        let cacheDir = ModelDownloader.cacheSnapshotDirectory(for: modelID)
        let modelDir = ModelDownloader.cacheModelDirectory(for: modelID)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        let downloader = ModelDownloader(r2CDNURL: "https://cdn.example.test", urlSession: makeSession())
        let model = CatalogModel(id: modelID, s3Name: "unused", displayName: "Mismatch", sizeGb: 0.001,
                                 r2Prefix: prefix, aggregateSHA256: manifest.aggregateSHA256)

        await #expect(throws: ModelCatalogError.self) {
            try await downloader.prefetch(model: model, manifest: manifest)
        }
        // Nothing was published to the live snapshot dir.
        #expect(!FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent("config.json").path))
    }

    @Test("prefetch honors cancellation mid-flight")
    func prefetchCancellation() async throws {
        PrefetchURLProtocol.reset()
        let modelID = "test-org/prefetch-cancel-\(UUID().uuidString)"
        let prefix = "v2/prefetch-cancel/v1"
        // Many files so the sequential loop has cancellation checkpoints.
        var files: [ManifestFile] = []
        var served: [String: Data] = [:]
        var pairs: [(String, Data)] = []
        for i in 0..<20 {
            let bytes = Data("file-\(i)-payload".utf8)
            let name = "file-\(i).bin"
            files.append(ManifestFile(path: name, sizeBytes: Int64(bytes.count), sha256: sha256Hex(bytes), role: "other"))
            served["/\(prefix)/\(name)"] = bytes
            pairs.append((name, bytes))
        }
        let manifest = ModelManifest(
            schemaVersion: 1, modelID: modelID, version: "v1", r2Prefix: prefix,
            aggregateSHA256: aggregateHash(files: pairs),
            totalSizeBytes: Int64(pairs.reduce(0) { $0 + $1.1.count }),
            fileCount: files.count, files: files, createdAt: Date(timeIntervalSince1970: 0)
        )
        PrefetchURLProtocol.files = served

        let modelDir = ModelDownloader.cacheModelDirectory(for: modelID)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        let downloader = ModelDownloader(r2CDNURL: "https://cdn.example.test", urlSession: makeSession())
        let model = CatalogModel(id: modelID, s3Name: "unused", displayName: "Cancel", sizeGb: 0.001,
                                 r2Prefix: prefix, aggregateSHA256: manifest.aggregateSHA256)

        let cacheDir = ModelDownloader.cacheSnapshotDirectory(for: modelID)
        let task = Task {
            try await downloader.prefetch(model: model, manifest: manifest)
        }
        // Cancel almost immediately so the sequential loop trips a checkpoint.
        task.cancel()
        // The invariant: a cancelled prefetch must throw and must NOT publish a
        // (partial) snapshot. The exact error type can be CancellationError (loop
        // checkpoint) or a wrapped download failure (in-flight transfer aborted);
        // either is acceptable as long as nothing is published.
        var threw = false
        do {
            try await task.value
        } catch {
            threw = true
        }
        #expect(threw)
        #expect(!FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent("file-0.bin").path))
    }

    // Aggregate hash matching the production `WeightHasher.hashFilesWithRelativeKey`
    // ordering (sorted by sortKey == relative path).
    private func aggregateHash(files: [(String, Data)]) -> String {
        let sorted = files.sorted { $0.0 < $1.0 }
        var hasher = SHA256()
        for (_, data) in sorted {
            var fileHasher = SHA256()
            fileHasher.update(data: data)
            let digest = fileHasher.finalize()
            hasher.update(data: Data(digest))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@Suite("AdvertisedModelStore", .serialized)
struct AdvertisedModelStoreTests {

    private func info(_ id: String, gb: Double = 1.0) -> ModelInfo {
        ModelInfo(id: id, sizeBytes: 1, estimatedMemoryGb: gb)
    }

    @Test("seeds from initial models, dedups by id, preserves order")
    func seedDedupOrder() {
        let store = AdvertisedModelStore([info("a"), info("b"), info("a", gb: 9)])
        #expect(store.models.map(\.id) == ["a", "b"])
        // First-seen wins for ordering; later dupes refresh nothing on seed.
        #expect(store.contains("a"))
        #expect(store.contains("b"))
        #expect(!store.contains("c"))
    }

    @Test("add appends new models and keeps existing ones (old + new union)")
    func addUnion() {
        let store = AdvertisedModelStore([info("old")])
        let wasNew = store.add(info("new"))
        #expect(wasNew)
        #expect(store.models.map(\.id) == ["old", "new"])
        // Adding an existing id is not "new" and never drops anything.
        let again = store.add(info("old", gb: 42))
        #expect(!again)
        #expect(store.models.count == 2)
        #expect(store.model(id: "old")?.estimatedMemoryGb == 42) // refreshed in place
    }
}

@Suite("CoordinatorClient advertiseModel", .serialized)
struct CoordinatorAdvertiseTests {

    @Test("advertiseModel adds to the advertised set (old + new both present)")
    func advertiseAddsToSet() async {
        let oldModel = ModelInfo(id: "org/old", sizeBytes: 1, estimatedMemoryGb: 1)
        let newModel = ModelInfo(id: "org/new", sizeBytes: 1, estimatedMemoryGb: 1)
        let hardware = HardwareInfo(
            machineModel: "Mac16,5",
            chipName: "Apple M4 Max",
            chipFamily: .m4,
            chipTier: .max,
            memoryGb: 128,
            memoryAvailableGb: 124,
            cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40,
            memoryBandwidthGbs: 546
        )
        let config = CoordinatorClientConfig(
            url: "ws://127.0.0.1:0/ignored",
            hardware: hardware,
            models: [oldModel],
            backendName: "mlx-swift"
        )
        let client = CoordinatorClient(config: config, stats: AtomicProviderStats(), state: ProviderState())

        // Not connected → advertiseModel updates the in-memory set and returns
        // true without throwing (re-register is deferred to the next reconnect).
        let isNew = await client.advertiseModel(newModel)
        #expect(isNew)
        let advertised = await client.currentAdvertisedModels().map(\.id).sorted()
        #expect(advertised == ["org/new", "org/old"]) // BOTH advertised

        // Duplicate advertise of the same id is a no-op (not new).
        let again = await client.advertiseModel(newModel)
        #expect(!again)
    }
}
