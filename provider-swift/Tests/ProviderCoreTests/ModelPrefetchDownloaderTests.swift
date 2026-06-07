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
    /// paths that should FAIL with a transport error (simulating a network
    /// drop). Used by the interrupt/resume test to abort mid-prefetch.
    nonisolated(unsafe) static var failPaths: Set<String> = []
    /// If set, only the FIRST `dropAfterBytes` bytes of a matching path are
    /// delivered before the connection is dropped (true mid-stream interrupt).
    nonisolated(unsafe) static var dropAfterBytes: [String: Int] = [:]
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); files = [:]; requestedPaths = []; failPaths = []; dropAfterBytes = [:]; lock.unlock()
    }

    static func record(_ path: String) {
        lock.lock(); requestedPaths.append(path); lock.unlock()
    }

    static func fetchedPaths() -> [String] {
        lock.lock(); defer { lock.unlock() }; return requestedPaths
    }

    /// Clear only the request log (keep `files`), so a second prefetch round can
    /// assert exactly which paths IT touched.
    static func clearRequested() {
        lock.lock(); requestedPaths = []; lock.unlock()
    }

    static func setFailPaths(_ paths: Set<String>) {
        lock.lock(); failPaths = paths; lock.unlock()
    }

    private static func shouldFail(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return failPaths.contains(path)
    }

    private static func dropBytes(_ path: String) -> Int? {
        lock.lock(); defer { lock.unlock() }; return dropAfterBytes[path]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let path = url.path
        Self.record(path)
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
        // connection so the transfer aborts partway through.
        if let drop = Self.dropBytes(path), drop < data.count {
            client?.urlProtocol(self, didLoad: data.prefix(drop))
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
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
        var files: [ManifestFile] = []
        var served: [String: Data] = [:]
        var pairs: [(String, Data)] = []
        for name in names {
            // Large enough that a prefix is a meaningful partial.
            let bytes = Data((0..<4096).map { UInt8(($0 &* 31 &+ name.count) & 0xFF) })
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

        // Attempt 1: config lands fine; weights drop after 1500/4096 bytes on
        // every attempt → the file's 3 retries exhaust and prefetch throws.
        PrefetchURLProtocol.dropAfterBytes = ["/\(prefix)/\(names[1])": 1500]

        var threw = false
        do { try await downloader.prefetch(model: model, manifest: manifest) } catch { threw = true }
        #expect(threw)
        // config completed and survives; snapshot not published.
        let stagingName = ".prefetch-staging-" + prefix.replacingOccurrences(of: "/", with: "__")
        let stagingDir = cacheDir.deletingLastPathComponent().appendingPathComponent(stagingName, isDirectory: true)
        #expect(ModelDownloader.fileMatches(stagingDir.appendingPathComponent(names[0]), size: files[0].sizeBytes, sha256: files[0].sha256))
        #expect(!FileManager.default.fileExists(atPath: cacheDir.path))

        // Attempt 2: healthy. config skipped, weights fetched to completion.
        PrefetchURLProtocol.dropAfterBytes = [:]
        PrefetchURLProtocol.clearRequested()
        try await downloader.prefetch(model: model, manifest: manifest)

        let round2 = Set(PrefetchURLProtocol.fetchedPaths())
        #expect(!round2.contains("/\(prefix)/\(names[0])"), "completed config must not be re-fetched")
        #expect(round2.contains("/\(prefix)/\(names[1])"))
        #expect(try Data(contentsOf: cacheDir.appendingPathComponent(names[1])) == served["/\(prefix)/\(names[1])"])
        #expect(!FileManager.default.fileExists(atPath: stagingDir.path))
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
