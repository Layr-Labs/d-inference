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
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); files = [:]; requestedPaths = []; lock.unlock()
    }

    static func record(_ path: String) {
        lock.lock(); requestedPaths.append(path); lock.unlock()
    }

    static func fetchedPaths() -> [String] {
        lock.lock(); defer { lock.unlock() }; return requestedPaths
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let path = url.path
        Self.record(path)
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
