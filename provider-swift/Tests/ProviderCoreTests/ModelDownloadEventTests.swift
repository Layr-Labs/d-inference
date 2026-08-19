import Crypto
import Foundation
import Testing
@testable import ProviderCore
import ProviderCoreFoundation

// MARK: - URLProtocol serving manifest + model bytes, honoring Range

private final class DownloadEventURLProtocol: URLProtocol, @unchecked Sendable {
    /// path (e.g. "/v2/prefix/config.json") → bytes served for it.
    nonisolated(unsafe) static var files: [String: Data] = [:]
    nonisolated(unsafe) static var requestedPaths: [String] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); files = [:]; requestedPaths = []; lock.unlock()
    }

    static func record(_ path: String) {
        lock.lock(); requestedPaths.append(path); lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let path = url.path
        Self.record(path)
        guard let body = Self.files[path] else {
            let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
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

private final class DownloadEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ModelDownloader.DownloadEvent] = []
    func append(_ event: ModelDownloader.DownloadEvent) {
        lock.lock(); storage.append(event); lock.unlock()
    }
    var events: [ModelDownloader.DownloadEvent] {
        lock.withLock { storage }
    }
}

private func downloadEventSHA256Hex(_ data: Data) -> String {
    var hasher = SHA256()
    hasher.update(data: data)
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Aggregate hash matching the production `WeightHasher.hashFilesWithRelativeKey`
/// ordering (sorted by sortKey == relative path).
private func downloadEventAggregateHash(files: [(String, Data)]) -> String {
    let sorted = files.sorted { $0.0 < $1.0 }
    var hasher = SHA256()
    for (_, data) in sorted {
        var fileHasher = SHA256()
        fileHasher.update(data: data)
        hasher.update(data: Data(fileHasher.finalize()))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

@Suite("ModelDownloader download events (machine progress feed)", .serialized)
struct ModelDownloadEventTests {

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DownloadEventURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeManifestFixture(modelID: String) -> (
        prefix: String, model: CatalogModel, manifest: ModelManifest, files: [(String, Data)]
    ) {
        let prefix = "v2/events/v1"
        let configBytes = Data(#"{ "model_type": "test" }"#.utf8)
        // 64 KiB > one delegate chunk: guarantees multiple progress events.
        let weightBytes = Data((0..<(64 * 1024)).map { UInt8($0 % 251) })
        let pairs: [(String, Data)] = [
            ("config.json", configBytes),
            ("model.safetensors", weightBytes),
        ]
        let aggregate = downloadEventAggregateHash(files: pairs)
        let manifestFiles = pairs.map {
            ManifestFile(path: $0.0, sizeBytes: Int64($0.1.count), sha256: downloadEventSHA256Hex($0.1), role: "weight")
        }
        let total = pairs.reduce(0) { $0 + $1.1.count }
        let manifest = ModelManifest(
            schemaVersion: 1, modelID: modelID, version: "v1", r2Prefix: prefix,
            aggregateSHA256: aggregate, totalSizeBytes: Int64(total),
            fileCount: manifestFiles.count, files: manifestFiles,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let model = CatalogModel(
            id: modelID, s3Name: "unused", displayName: "Events", sizeGb: 0.001,
            r2Prefix: prefix, aggregateSHA256: aggregate
        )
        return (prefix, model, manifest, pairs)
    }

    private static let manifestEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    @Test("manifest download emits per-file cumulative progress then exactly one verifying event, last")
    func manifestHappyPath() async throws {
        DownloadEventURLProtocol.reset()
        let modelID = "test-org/events-happy-\(UUID().uuidString)"
        let (prefix, model, manifest, pairs) = makeManifestFixture(modelID: modelID)
        let modelDir = ModelDownloader.cacheModelDirectory(for: modelID)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        DownloadEventURLProtocol.files = [
            "/\(prefix)/manifest.json": try Self.manifestEncoder.encode(manifest),
            "/\(prefix)/config.json": pairs[0].1,
            "/\(prefix)/model.safetensors": pairs[1].1,
        ]

        let box = DownloadEventBox()
        let downloader = ModelDownloader(r2CDNURL: "https://cdn.example.test", urlSession: makeSession())
        try await downloader.download(model: model, onEvent: { box.append($0) })

        let events = box.events
        let progress = events.filter { $0.phase == .progress }
        let verifying = events.filter { $0.phase == .verifying }

        // Verifying fires exactly once and is the terminal event.
        #expect(verifying.count == 1)
        #expect(verifying[0].file == modelID)
        #expect(events.last?.phase == .verifying)

        // Every file reports cumulative, monotonically non-decreasing bytes
        // ending exactly at its manifest size.
        for (name, bytes) in pairs {
            let fileEvents = progress.filter { $0.file == name }
            #expect(!fileEvents.isEmpty)
            #expect(fileEvents.allSatisfy { $0.bytesTotal == Int64(bytes.count) })
            #expect(fileEvents.last?.bytesDownloaded == Int64(bytes.count))
            var previous: Int64 = -1
            for event in fileEvents {
                #expect(event.bytesDownloaded >= previous)
                previous = event.bytesDownloaded
            }
        }

        // Snapshot published.
        let cacheDir = ModelDownloader.cacheSnapshotDirectory(for: modelID)
        #expect(FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent("config.json").path))
        #expect(FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent("model.safetensors").path))
    }

    @Test("a resumed .part prefix is credited in the file's first progress event")
    func resumedPrefixCredited() async throws {
        DownloadEventURLProtocol.reset()
        let modelID = "test-org/events-resume-\(UUID().uuidString)"
        let (prefix, model, manifest, pairs) = makeManifestFixture(modelID: modelID)
        let modelDir = ModelDownloader.cacheModelDirectory(for: modelID)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        // Pre-seed the stable staging dir with half of the weight file as a
        // `.part` (exact byte prefix, so the Range request resumes mid-file).
        let weightBytes = pairs[1].1
        let halfBytes = weightBytes.prefix(weightBytes.count / 2)
        let stagingDir = modelDir
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(
                ModelDownloader.localStagingDirName(r2Prefix: prefix), isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try halfBytes.write(to: stagingDir.appendingPathComponent("model.safetensors.part"))

        DownloadEventURLProtocol.files = [
            "/\(prefix)/manifest.json": try Self.manifestEncoder.encode(manifest),
            "/\(prefix)/config.json": pairs[0].1,
            "/\(prefix)/model.safetensors": weightBytes,
        ]

        let box = DownloadEventBox()
        let downloader = ModelDownloader(r2CDNURL: "https://cdn.example.test", urlSession: makeSession())
        try await downloader.download(model: model, onEvent: { box.append($0) })

        let weightEvents = box.events.filter { $0.file == "model.safetensors" }
        // The register event credits the on-disk prefix: the bar starts at
        // the half-file mark instead of restarting at zero.
        #expect(weightEvents.first?.bytesDownloaded == Int64(halfBytes.count))
        #expect(weightEvents.last?.bytesDownloaded == Int64(weightBytes.count))
        #expect(box.events.last?.phase == .verifying)

        // The resumed file verified and published.
        let cacheDir = ModelDownloader.cacheSnapshotDirectory(for: modelID)
        #expect(try Data(contentsOf: cacheDir.appendingPathComponent("model.safetensors")) == weightBytes)
    }

    @Test("legacy download emits totals-free progress events and no verifying phase")
    func legacyPath() async throws {
        DownloadEventURLProtocol.reset()
        let modelID = "test-org/events-legacy-\(UUID().uuidString)"
        let s3 = "test-org/legacy-weights"
        let modelDir = ModelDownloader.cacheModelDirectory(for: modelID)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        let configBytes = Data(#"{ "architectures": ["Test"] }"#.utf8)
        let weightBytes = Data((0..<(32 * 1024)).map { UInt8($0 % 241) })
        DownloadEventURLProtocol.files = [
            "/\(s3)/config.json": configBytes,
            "/\(s3)/model.safetensors": weightBytes,
        ]

        let model = CatalogModel(
            id: modelID, s3Name: s3, displayName: "Legacy", sizeGb: 0.001
        )

        let box = DownloadEventBox()
        let downloader = ModelDownloader(r2CDNURL: "https://cdn.example.test", urlSession: makeSession())
        try await downloader.download(model: model, onEvent: { box.append($0) })

        let events = box.events
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.phase == .progress })
        #expect(events.allSatisfy { $0.bytesTotal == nil })
        let weightEvents = events.filter { $0.file == "model.safetensors" }
        #expect(weightEvents.last?.bytesDownloaded == Int64(weightBytes.count))

        let cacheDir = ModelDownloader.cacheSnapshotDirectory(for: modelID)
        #expect(FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent("model.safetensors").path))
    }
}
