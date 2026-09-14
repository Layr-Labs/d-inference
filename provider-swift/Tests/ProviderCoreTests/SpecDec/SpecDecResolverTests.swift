/// SpecDecResolverTests -- live-isolated tests for the spec-dec drafter
/// fetcher (plan D2). A real Hummingbird HTTP server on 127.0.0.1:0 (the
/// MockCoordinator pattern) plays the model CDN, serving a tiny fake drafter
/// manifest + files; the resolver runs against a throwaway store root.

import Crypto
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdCore
import Logging
import NIOCore
import Testing
@testable import ProviderCore
import ProviderCoreFoundation

// MARK: - Local CDN fixture

/// Minimal file-serving HTTP server: path -> bytes, with a request log so
/// tests can prove which paths were (not) fetched. Honors `Range: bytes=N-`
/// the way the real CDN does, since the downloader byte-resumes.
private final class SpecDecFileServer: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var requested: [String] = []
    private var serverTask: Task<Void, Never>?
    private var responseDelayNanoseconds: UInt64 = 0

    func setFiles(_ files: [String: Data]) {
        lock.lock(); self.files = files; lock.unlock()
    }

    func requestedPaths() -> [String] {
        lock.lock(); defer { lock.unlock() }; return requested
    }

    func clearRequested() {
        lock.lock(); requested = []; lock.unlock()
    }

    func setResponseDelay(milliseconds: UInt64) {
        lock.withLock { responseDelayNanoseconds = milliseconds * 1_000_000 }
    }

    private func record(_ path: String) {
        lock.lock(); requested.append(path); lock.unlock()
    }

    private func body(for path: String) -> Data? {
        lock.lock(); defer { lock.unlock() }; return files[path]
    }

    private func responseDelay() -> UInt64 {
        lock.withLock { responseDelayNanoseconds }
    }

    /// Bind 127.0.0.1 on a system-assigned port and return the base URL.
    func start() async throws -> URL {
        var logger = Logger(label: "SpecDecFileServer")
        logger.logLevel = .critical

        let router = Router(context: BasicRequestContext.self)
        router.get("**") { [weak self] request, _ -> Response in
            guard let self else { return Response(status: .internalServerError) }
            let path = request.uri.path
            self.record(path)
            let delay = self.responseDelay()
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard let full = self.body(for: path) else {
                return Response(status: .notFound)
            }
            var data = full
            var status = HTTPResponse.Status.ok
            var headers = HTTPFields()
            if let range = request.headers[.range],
               range.hasPrefix("bytes="), range.hasSuffix("-"),
               let start = Int(range.dropFirst("bytes=".count).dropLast()), start <= full.count
            {
                data = Data(full.dropFirst(start))
                status = .partialContent
                headers[.contentRange] = "bytes \(start)-\(full.count - 1)/\(full.count)"
            }
            return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
        }

        let portBox = OneShotPortBox()
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: 0), serverName: "SpecDecFileServer"),
            onServerRunning: { @Sendable channel in
                portBox.complete(channel.localAddress?.port ?? 0)
            },
            logger: logger
        )
        let task = Task<Void, Never> {
            do {
                try await app.runService(gracefulShutdownSignals: [])
            } catch {
                logger.warning("SpecDecFileServer crashed: \(error)")
            }
        }

        let port = await portBox.value
        guard port > 0 else {
            task.cancel()
            throw URLError(.cannotConnectToHost)
        }
        lock.withLock { serverTask = task }
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    func shutdown() async {
        let task: Task<Void, Never>? = lock.withLock {
            let t = serverTask
            serverTask = nil
            return t
        }
        task?.cancel()
        _ = await task?.value
    }
}

/// One-shot async box for the bound port (MockCoordinator's PortBox pattern).
private final class OneShotPortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var port: Int?
    private var continuation: CheckedContinuation<Int, Never>?

    var value: Int {
        get async {
            await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
                lock.withLock {
                    if let p = port { cont.resume(returning: p) } else { continuation = cont }
                }
            }
        }
    }

    func complete(_ port: Int) {
        let cont: CheckedContinuation<Int, Never>? = lock.withLock {
            if self.port != nil { return nil }
            self.port = port
            let cont = continuation
            continuation = nil
            return cont
        }
        cont?.resume(returning: port)
    }
}

// MARK: - Fixture helpers

private func sha256Hex(_ data: Data) -> String {
    var hasher = SHA256()
    hasher.update(data: data)
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func aggregateHex(_ files: [(String, Data)]) -> String {
    var aggregate = SHA256()
    for (_, data) in files.sorted(by: { $0.0 < $1.0 }) {
        let digest = SHA256.hash(data: data)
        digest.withUnsafeBytes { aggregate.update(bufferPointer: $0) }
    }
    return aggregate.finalize().map { String(format: "%02x", $0) }.joined()
}

/// A tiny two-file drafter artifact (config + weights), deterministic bytes.
private struct DrafterFixture {
    let prefix: String
    let configBytes: Data
    let weightBytes: Data
    let manifest: ModelManifest

    /// - Parameter corruptWeightSHA: when true, the manifest lists a SHA-256
    ///   for the weight file that does NOT match the served bytes.
    init(prefix: String, corruptWeightSHA: Bool = false) {
        self.prefix = prefix
        self.configBytes = Data(#"{"model_type": "gemma4_assistant"}"#.utf8)
        self.weightBytes = Data((0..<4096).map { UInt8(($0 &* 31 &+ 7) & 0xFF) })
        let weightSHA = corruptWeightSHA
            ? String(repeating: "d", count: 64)
            : sha256Hex(weightBytes)
        self.manifest = ModelManifest(
            schemaVersion: 1,
            // Deliberately NOT a catalog model id: the drafter artifact is its
            // own publish, and the resolver must not pin manifest.model_id to
            // the target model (plan D3: no registry pinning).
            modelID: "darkbloom/gemma4-drafter-4bit",
            version: "v1",
            r2Prefix: prefix,
            aggregateSHA256: aggregateHex([
                ("config.json", configBytes), ("model.safetensors", weightBytes),
            ]),
            totalSizeBytes: Int64(configBytes.count + weightBytes.count),
            fileCount: 2,
            files: [
                ManifestFile(path: "config.json", sizeBytes: Int64(configBytes.count),
                             sha256: sha256Hex(configBytes), role: "config"),
                ManifestFile(path: "model.safetensors", sizeBytes: Int64(weightBytes.count),
                             sha256: weightSHA, role: "weight"),
            ],
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    /// path -> bytes map for the file server (manifest.json + both files).
    func served() throws -> [String: Data] {
        return [
            "/\(prefix)/manifest.json": try manifestData(),
            "/\(prefix)/config.json": configBytes,
            "/\(prefix)/model.safetensors": weightBytes,
        ]
    }

    func manifestData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(manifest)
    }
}

private func makeModel(id: String, specDecPrefix: String?) -> CatalogModel {
    var metadata: [String: JSONValue]?
    if let specDecPrefix {
        metadata = ["spec_dec": .object([("r2_prefix", .string(specDecPrefix))])]
    }
    return CatalogModel(
        id: id, s3Name: "unused", displayName: id, sizeGb: 15.0,
        r2Prefix: "v2/\(id)/v1", metadata: metadata
    )
}

private func makePinnedModel(id: String, fixture: DrafterFixture) throws -> CatalogModel {
    let manifestData = try fixture.manifestData()
    return makeTrustedModel(
        id: id,
        prefix: fixture.prefix,
        manifestData: manifestData,
        totalSizeBytes: fixture.manifest.totalSizeBytes,
        fileCount: fixture.manifest.fileCount,
        configSHA256: sha256Hex(fixture.configBytes),
        revision: fixture.manifest.version)
}

private func makeTrustedModel(
    id: String,
    prefix: String,
    manifestData: Data,
    totalSizeBytes: Int64,
    fileCount: Int,
    configSHA256: String,
    revision: String,
    manifestSHA256: String? = nil,
    maximumFileCount: Int = 64
) -> CatalogModel {
    let metadata: [String: JSONValue] = [
        "spec_dec": .object([
            ("r2_prefix", .string(prefix)),
            ("manifest_sha256", .string(manifestSHA256 ?? sha256Hex(manifestData))),
            ("total_size_bytes", .int(totalSizeBytes)),
            ("file_count", .int(Int64(fileCount))),
            ("max_file_count", .int(Int64(maximumFileCount))),
            ("allowed_file_types", .array([.string("config"), .string("weight")])),
            ("config_sha256", .string(configSHA256)),
            ("revision", .string(revision)),
        ])
    ]
    return CatalogModel(
        id: id, s3Name: "unused", displayName: id, sizeGb: 15,
        metadata: metadata)
}

private func makeTempStoreRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("specdec-resolver-tests-\(UUID().uuidString)", isDirectory: true)
}

// MARK: - Tests

@Suite("SpecDecResolver (drafter fetch + store)", .serialized)
struct SpecDecResolverTests {

    @Test("happy path: downloads via manifest, verifies per-file SHA, publishes atomically")
    func happyPathDownloadsAndPublishes() async throws {
        let server = SpecDecFileServer()
        let baseURL = try await server.start()
        defer { Task { await server.shutdown() } }

        let prefix = "v2-specdec/gemma4-26b-assistant-4bit/v1"
        let fixture = DrafterFixture(prefix: prefix)
        server.setFiles(try fixture.served())

        let storeRoot = makeTempStoreRoot()
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let resolver = SpecDecResolver(storeRoot: storeRoot, cdnBaseURL: baseURL.absoluteString)
        let model = try makePinnedModel(id: "gemma-4-26b-qat", fixture: fixture)

        let cold = await resolver.resolve(model: model, allowDownload: true)
        #expect(cold.artifact == nil)
        #expect(cold.reason == .artifactNotCached)
        let resolved = try #require(await resolver.prefetch(model: model).artifact?.directory)

        // Resolved dir lives under the store root (never the HF cache) and is
        // keyed by the prefix hash.
        #expect(resolved.path.hasPrefix(storeRoot.path))
        #expect(resolved.lastPathComponent == SpecDecStore.key(forR2Prefix: prefix))
        // Contents are byte-exact and the manifest was stored alongside.
        #expect(try Data(contentsOf: resolved.appendingPathComponent("config.json")) == fixture.configBytes)
        #expect(try Data(contentsOf: resolved.appendingPathComponent("model.safetensors")) == fixture.weightBytes)
        let storedManifest = try ModelCatalogClient.manifestDecoder.decode(
            ModelManifest.self, from: Data(contentsOf: resolved.appendingPathComponent("manifest.json")))
        #expect(storedManifest == fixture.manifest)
        // Staging was consumed by the atomic publish.
        let remaining = try FileManager.default.contentsOfDirectory(
            at: storeRoot, includingPropertiesForKeys: nil)
        #expect(!remaining.contains { $0.lastPathComponent.hasPrefix(".staging-") })
    }

    @Test("corrupt file (SHA mismatch after retries) fails open: nil, nothing published")
    func corruptFileReturnsNil() async throws {
        let server = SpecDecFileServer()
        let baseURL = try await server.start()
        defer { Task { await server.shutdown() } }

        let prefix = "v2-specdec/gemma4-corrupt/v1"
        let fixture = DrafterFixture(prefix: prefix, corruptWeightSHA: true)
        server.setFiles(try fixture.served())

        let storeRoot = makeTempStoreRoot()
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let resolver = SpecDecResolver(storeRoot: storeRoot, cdnBaseURL: baseURL.absoluteString)
        let model = try makePinnedModel(id: "gemma-4-26b-qat", fixture: fixture)

        let result = await resolver.prefetch(model: model)
        #expect(result.artifact == nil)
        #expect(result.reason == .fileDigestMismatch)
        // Nothing was published: the artifact dir does not exist.
        let artifactDir = SpecDecStore.artifactDirectory(root: storeRoot, r2Prefix: prefix)
        #expect(!FileManager.default.fileExists(atPath: artifactDir.path))
    }

    @Test("missing/malformed spec_dec metadata fails open: nil, zero network traffic")
    func missingMetadataReturnsNil() async throws {
        let server = SpecDecFileServer()
        let baseURL = try await server.start()
        defer { Task { await server.shutdown() } }

        let storeRoot = makeTempStoreRoot()
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let resolver = SpecDecResolver(storeRoot: storeRoot, cdnBaseURL: baseURL.absoluteString)

        // No metadata at all.
        let bare = makeModel(id: "gemma-4-26b-qat", specDecPrefix: nil)
        #expect(await resolver.drafterDirectory(for: bare, allowDownload: true) == nil)

        // Metadata present but no spec_dec key.
        let unrelated = CatalogModel(
            id: "gemma-4-26b-8bit", s3Name: "unused", displayName: "g", sizeGb: 15.0,
            metadata: ["other": .string("x")]
        )
        #expect(await resolver.drafterDirectory(for: unrelated, allowDownload: true) == nil)

        // spec_dec present but r2_prefix missing / wrong type / empty.
        let noPrefix = CatalogModel(
            id: "gemma-4-26b-8bit", s3Name: "unused", displayName: "g", sizeGb: 15.0,
            metadata: ["spec_dec": .object([("r2_prefix", .int(7))])]
        )
        #expect(await resolver.drafterDirectory(for: noPrefix, allowDownload: true) == nil)
        let emptyPrefix = CatalogModel(
            id: "gemma-4-26b-8bit", s3Name: "unused", displayName: "g", sizeGb: 15.0,
            metadata: ["spec_dec": .object([("r2_prefix", .string(""))])]
        )
        #expect(await resolver.drafterDirectory(for: emptyPrefix, allowDownload: true) == nil)

        // The CDN was never touched for any of them.
        #expect(server.requestedPaths().isEmpty)
        // And the helper mirrors the same decode.
        #expect(SpecDecResolver.specDecR2Prefix(for: bare) == nil)
        #expect(SpecDecResolver.specDecR2Prefix(for: makeModel(id: "m", specDecPrefix: "p/q")) == nil)
    }

    @Test("manifest 404 fails open: nil, nothing published")
    func manifestHTTPErrorReturnsNil() async throws {
        let server = SpecDecFileServer()
        let baseURL = try await server.start()
        defer { Task { await server.shutdown() } }
        // Serve nothing: manifest.json fetch gets a 404.

        let storeRoot = makeTempStoreRoot()
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let resolver = SpecDecResolver(storeRoot: storeRoot, cdnBaseURL: baseURL.absoluteString)
        let prefix = "v2-specdec/missing/v1"
        let model = makeTrustedModel(
            id: "gemma-4-26b-qat", prefix: prefix,
            manifestData: Data("missing".utf8), totalSizeBytes: 2,
            fileCount: 2, configSHA256: String(repeating: "0", count: 64),
            revision: "v1")

        #expect(await resolver.prefetch(model: model).reason == .manifestFetchFailed)
        #expect(!FileManager.default.fileExists(
            atPath: SpecDecStore.artifactDirectory(root: storeRoot, r2Prefix: prefix).path))
    }

    @Test("warm re-resolve returns the stored copy with zero network traffic")
    func warmReResolveSkipsDownload() async throws {
        let server = SpecDecFileServer()
        let baseURL = try await server.start()
        defer { Task { await server.shutdown() } }

        let prefix = "v2-specdec/gemma4-warm/v1"
        let fixture = DrafterFixture(prefix: prefix)
        server.setFiles(try fixture.served())

        let storeRoot = makeTempStoreRoot()
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let resolver = SpecDecResolver(storeRoot: storeRoot, cdnBaseURL: baseURL.absoluteString)
        let model = try makePinnedModel(id: "gemma-4-26b-qat", fixture: fixture)

        let first = try #require(await resolver.prefetch(model: model).artifact?.directory)
        #expect(!server.requestedPaths().isEmpty)

        server.clearRequested()
        let second = try #require(await resolver.resolve(model: model, allowDownload: true).artifact?.directory)
        #expect(second == first)
        #expect(server.requestedPaths().isEmpty, "warm re-resolve must not touch the CDN")

        // allowDownload: false also resolves a verified stored copy.
        let third = try #require(await resolver.resolve(model: model, allowDownload: false).artifact?.directory)
        #expect(third == first)
        #expect(server.requestedPaths().isEmpty)
    }

    @Test("allowDownload: false with no stored copy fails open without touching the CDN")
    func allowDownloadFalseWithoutCopyReturnsNil() async throws {
        let server = SpecDecFileServer()
        let baseURL = try await server.start()
        defer { Task { await server.shutdown() } }

        let prefix = "v2-specdec/gemma4-nodownload/v1"
        let fixture = DrafterFixture(prefix: prefix)
        server.setFiles(try fixture.served())

        let storeRoot = makeTempStoreRoot()
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let resolver = SpecDecResolver(storeRoot: storeRoot, cdnBaseURL: baseURL.absoluteString)
        let model = try makePinnedModel(id: "gemma-4-26b-qat", fixture: fixture)

        #expect(await resolver.resolve(model: model, allowDownload: false).reason == .artifactNotCached)
        #expect(server.requestedPaths().isEmpty)
    }

    @Test("two builds sharing one spec_dec prefix share one download")
    func sharedPrefixReusesOneDownload() async throws {
        let server = SpecDecFileServer()
        let baseURL = try await server.start()
        defer { Task { await server.shutdown() } }

        let prefix = "v2-specdec/gemma4-shared/v1"
        let fixture = DrafterFixture(prefix: prefix)
        server.setFiles(try fixture.served())

        let storeRoot = makeTempStoreRoot()
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let resolver = SpecDecResolver(storeRoot: storeRoot, cdnBaseURL: baseURL.absoluteString)

        // Two DIFFERENT catalog builds (qat + 8bit) point at the same artifact.
        let qat = try makePinnedModel(id: "gemma-4-26b-qat", fixture: fixture)
        let eightBit = try makePinnedModel(id: "gemma-4-26b-8bit", fixture: fixture)

        let qatDir = try #require(await resolver.prefetch(model: qat).artifact?.directory)
        server.clearRequested()

        let eightBitDir = try #require(await resolver.resolve(model: eightBit, allowDownload: true).artifact?.directory)
        #expect(eightBitDir == qatDir, "both builds must resolve to the same stored artifact")
        #expect(server.requestedPaths().isEmpty, "the second build must reuse the first download")
    }

    @Test("production metadata pins manifest, total bytes, file count, roles, config, and revision")
    func productionMetadataPinsArtifact() async throws {
        let server = SpecDecFileServer()
        let baseURL = try await server.start()
        defer { Task { await server.shutdown() } }
        let fixture = DrafterFixture(prefix: "v2-specdec/gemma4-pinned/v1")
        server.setFiles(try fixture.served())
        let root = makeTempStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = SpecDecResolver(storeRoot: root, cdnBaseURL: baseURL.absoluteString)

        let result = await resolver.prefetch(
            model: try makePinnedModel(id: "gemma-4-26b-qat", fixture: fixture))
        let artifact = try #require(result.artifact)
        #expect(result.reason == nil)
        #expect(artifact.artifactBytes == UInt64(fixture.manifest.totalSizeBytes))
        #expect(artifact.residentBytes == SpecDecLimits.residentEstimate(
            artifactBytes: UInt64(fixture.manifest.totalSizeBytes)))
        #expect(artifact.revision == "v1")
        #expect(artifact.manifestSHA256 == sha256Hex(try fixture.manifestData()))
    }

    @Test("catalog manifest digest mismatch is rejected before any file download")
    func manifestDigestMismatch() async throws {
        let server = SpecDecFileServer()
        let baseURL = try await server.start()
        defer { Task { await server.shutdown() } }
        let fixture = DrafterFixture(prefix: "v2-specdec/gemma4-manifest-digest/v1")
        server.setFiles(try fixture.served())
        let model = makeTrustedModel(
            id: "gemma-4", prefix: fixture.prefix,
            manifestData: try fixture.manifestData(),
            totalSizeBytes: fixture.manifest.totalSizeBytes,
            fileCount: fixture.manifest.fileCount,
            configSHA256: sha256Hex(fixture.configBytes),
            revision: fixture.manifest.version,
            manifestSHA256: String(repeating: "a", count: 64))
        let root = makeTempStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await SpecDecResolver(
            storeRoot: root, cdnBaseURL: baseURL.absoluteString
        ).prefetch(model: model)
        #expect(result.reason == .manifestDigestMismatch)
        #expect(server.requestedPaths() == ["/\(fixture.prefix)/manifest.json"])
    }

    @Test("path traversal in manifest is rejected")
    func pathTraversalRejected() async throws {
        let server = SpecDecFileServer()
        let baseURL = try await server.start()
        defer { Task { await server.shutdown() } }
        let prefix = "v2-specdec/gemma4-traversal/v1"
        let config = Data("{}".utf8)
        let manifest = ModelManifest(
            schemaVersion: 1, modelID: "assistant", version: "v1", r2Prefix: prefix,
            aggregateSHA256: String(repeating: "0", count: 64),
            totalSizeBytes: Int64(config.count + 1), fileCount: 2,
            files: [
                .init(path: "config.json", sizeBytes: Int64(config.count), sha256: sha256Hex(config), role: "config"),
                .init(path: "../model.safetensors", sizeBytes: 1, sha256: String(repeating: "0", count: 64), role: "weight"),
            ], createdAt: Date(timeIntervalSince1970: 0))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)
        server.setFiles(["/\(prefix)/manifest.json": manifestData])
        let root = makeTempStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeTrustedModel(
            id: "gemma-4", prefix: prefix, manifestData: manifestData,
            totalSizeBytes: manifest.totalSizeBytes, fileCount: manifest.fileCount,
            configSHA256: sha256Hex(config), revision: manifest.version)
        let result = await SpecDecResolver(
            storeRoot: root, cdnBaseURL: baseURL.absoluteString
        ).prefetch(model: model)
        #expect(result.reason == .pathInvalid)
    }

    @Test("artifact total and file count bounds reject hostile manifests")
    func sizeAndCountBounds() async throws {
        let server = SpecDecFileServer()
        let baseURL = try await server.start()
        defer { Task { await server.shutdown() } }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let oversizedPrefix = "v2-specdec/gemma4-oversize/v1"
        let oversized = ModelManifest(
            schemaVersion: 1, modelID: "assistant", version: "v1", r2Prefix: oversizedPrefix,
            aggregateSHA256: String(repeating: "0", count: 64),
            totalSizeBytes: Int64(SpecDecLimits.maximumArtifactBytes + 1), fileCount: 2,
            files: [
                .init(path: "config.json", sizeBytes: 1, sha256: String(repeating: "0", count: 64), role: "config"),
                .init(path: "model.safetensors", sizeBytes: 1, sha256: String(repeating: "0", count: 64), role: "weight"),
            ], createdAt: Date(timeIntervalSince1970: 0))
        let countPrefix = "v2-specdec/gemma4-count/v1"
        var files = [ManifestFile(
            path: "config.json", sizeBytes: 1,
            sha256: String(repeating: "0", count: 64), role: "config")]
        for index in 0..<SpecDecLimits.maximumFileCount {
            files.append(.init(
                path: "model-\(index).safetensors", sizeBytes: 1,
                sha256: String(repeating: "0", count: 64), role: "weight"))
        }
        let tooMany = ModelManifest(
            schemaVersion: 1, modelID: "assistant", version: "v1", r2Prefix: countPrefix,
            aggregateSHA256: String(repeating: "0", count: 64),
            totalSizeBytes: Int64(files.count), fileCount: files.count,
            files: files, createdAt: Date(timeIntervalSince1970: 0))
        let oversizedData = try encoder.encode(oversized)
        let tooManyData = try encoder.encode(tooMany)
        server.setFiles([
            "/\(oversizedPrefix)/manifest.json": oversizedData,
            "/\(countPrefix)/manifest.json": tooManyData,
        ])
        let root = makeTempStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = SpecDecResolver(storeRoot: root, cdnBaseURL: baseURL.absoluteString)
        let oversizedModel = makeTrustedModel(
            id: "gemma-4", prefix: oversizedPrefix, manifestData: oversizedData,
            totalSizeBytes: 2, fileCount: 2,
            configSHA256: String(repeating: "0", count: 64), revision: "v1")
        let countModel = makeTrustedModel(
            id: "gemma-4", prefix: countPrefix, manifestData: tooManyData,
            totalSizeBytes: Int64(files.count), fileCount: 2,
            configSHA256: String(repeating: "0", count: 64), revision: "v1",
            maximumFileCount: 2)
        #expect(await resolver.prefetch(model: oversizedModel).reason == .artifactOversize)
        #expect(await resolver.prefetch(model: countModel).reason == .fileCountInvalid)
    }

    @Test("concurrent same-prefix resolution publishes and downloads once")
    func concurrentReuse() async throws {
        let server = SpecDecFileServer()
        let baseURL = try await server.start()
        defer { Task { await server.shutdown() } }
        let fixture = DrafterFixture(prefix: "v2-specdec/gemma4-concurrent/v1")
        server.setFiles(try fixture.served())
        let root = makeTempStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = SpecDecResolver(storeRoot: root, cdnBaseURL: baseURL.absoluteString)
        let model = try makePinnedModel(id: "gemma-4", fixture: fixture)

        async let first = resolver.prefetch(model: model)
        async let second = resolver.prefetch(model: model)
        let results = await [first, second]
        #expect(results.allSatisfy { $0.artifact != nil })
        #expect(results[0].artifact?.directory == results[1].artifact?.directory)
        let paths = server.requestedPaths()
        #expect(paths.filter { $0.hasSuffix("manifest.json") }.count == 1)
        #expect(paths.filter { $0.hasSuffix("config.json") }.count == 1)
        #expect(paths.filter { $0.hasSuffix("model.safetensors") }.count == 1)
    }

    @Test("cancelling one of two coalesced waiters preserves the shared transfer")
    func oneCancelledWaiterDoesNotCancelPeer() async throws {
        let server = SpecDecFileServer()
        let baseURL = try await server.start()
        defer { Task { await server.shutdown() } }
        server.setResponseDelay(milliseconds: 100)
        let fixture = DrafterFixture(prefix: "v2-specdec/gemma4-two-waiters/v1")
        server.setFiles(try fixture.served())
        let root = makeTempStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = SpecDecResolver(storeRoot: root, cdnBaseURL: baseURL.absoluteString)
        let model = try makePinnedModel(id: "gemma-4", fixture: fixture)

        let first = Task { await resolver.prefetch(model: model) }
        let second = Task { await resolver.prefetch(model: model) }
        for _ in 0..<100 where server.requestedPaths().isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        first.cancel()
        let cancelled = await first.value
        let survivor = await second.value

        #expect(cancelled.artifact == nil)
        #expect(cancelled.detail == "MTP prefetch was cancelled")
        #expect(survivor.artifact != nil)
        let paths = server.requestedPaths()
        #expect(paths.filter { $0.hasSuffix("manifest.json") }.count == 1)
        #expect(paths.filter { $0.hasSuffix("config.json") }.count == 1)
        #expect(paths.filter { $0.hasSuffix("model.safetensors") }.count == 1)
    }

    @Test("cancelled final waiter cannot cancel a same-key successor")
    func delayedCancellationCannotCancelSuccessor() async throws {
        let server = SpecDecFileServer()
        let baseURL = try await server.start()
        defer { Task { await server.shutdown() } }
        server.setResponseDelay(milliseconds: 150)
        let fixture = DrafterFixture(prefix: "v2-specdec/gemma4-successor/v1")
        server.setFiles(try fixture.served())
        let root = makeTempStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = SpecDecResolver(storeRoot: root, cdnBaseURL: baseURL.absoluteString)
        let model = try makePinnedModel(id: "gemma-4", fixture: fixture)

        let predecessor = Task { await resolver.prefetch(model: model) }
        for _ in 0..<100 where server.requestedPaths().isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        predecessor.cancel()
        let cancelled = await predecessor.value
        #expect(cancelled.detail == "MTP prefetch was cancelled")

        server.clearRequested()
        let successor = await resolver.prefetch(model: model)
        #expect(successor.artifact != nil)
        let successorPaths = server.requestedPaths()
        #expect(successorPaths.filter { $0.hasSuffix("manifest.json") }.count == 1)
        #expect(successorPaths.filter { $0.hasSuffix("config.json") }.count == 1)
        #expect(successorPaths.filter { $0.hasSuffix("model.safetensors") }.count == 1)
    }

    @Test("warm same-size corruption is hash-detected and never size-trusted")
    func warmCorruptionDetected() async throws {
        let server = SpecDecFileServer()
        let baseURL = try await server.start()
        defer { Task { await server.shutdown() } }
        let fixture = DrafterFixture(prefix: "v2-specdec/gemma4-warm-corrupt/v1")
        server.setFiles(try fixture.served())
        let root = makeTempStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = SpecDecResolver(storeRoot: root, cdnBaseURL: baseURL.absoluteString)
        let model = try makePinnedModel(id: "gemma-4", fixture: fixture)
        let first = try #require(await resolver.prefetch(model: model).artifact)
        var corrupted = fixture.weightBytes
        corrupted[corrupted.startIndex] ^= 0xff
        try corrupted.write(to: first.directory.appendingPathComponent("model.safetensors"))
        server.clearRequested()

        let warm = await resolver.resolve(model: model, allowDownload: true)
        #expect(warm.artifact == nil)
        #expect(warm.reason == .warmArtifactCorrupt)
        #expect(server.requestedPaths().isEmpty)
    }

    @Test("catalog metadata requires every immutable trust anchor before network")
    func requiredTrustAnchors() async throws {
        let server = SpecDecFileServer()
        let baseURL = try await server.start()
        defer { Task { await server.shutdown() } }
        let fixture = DrafterFixture(prefix: "v2-specdec/gemma4-required-anchors/v1")
        server.setFiles(try fixture.served())
        let pinned = try makePinnedModel(id: "gemma-4", fixture: fixture)
        let pairs = try #require({ () -> [(String, JSONValue)]? in
            guard case .object(let value)? = pinned.metadata?["spec_dec"] else { return nil }
            return value
        }())
        let required = [
            "manifest_sha256", "total_size_bytes", "file_count", "max_file_count",
            "allowed_file_types", "config_sha256", "revision",
        ]
        let root = makeTempStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = SpecDecResolver(storeRoot: root, cdnBaseURL: baseURL.absoluteString)

        for omitted in required {
            let model = CatalogModel(
                id: "gemma-4-\(omitted)", s3Name: "unused", displayName: "g", sizeGb: 1,
                metadata: ["spec_dec": .object(pairs.filter { $0.0 != omitted })])
            let result = await resolver.resolve(model: model, allowDownload: true)
            #expect(result.artifact == nil)
            #expect(result.reason == .metadataMalformed, "omitted=\(omitted)")
        }
        let prefixOnly = await resolver.resolve(
            model: makeModel(id: "gemma-4-prefix-only", specDecPrefix: fixture.prefix),
            allowDownload: true)
        #expect(prefixOnly.artifact == nil)
        #expect(prefixOnly.reason == .metadataMalformed)
        #expect(server.requestedPaths().isEmpty)
    }

    @Test("cold catalog artifact returns immediately while owned prefetch continues")
    func coldResolutionIsNonblocking() async throws {
        let server = SpecDecFileServer()
        let baseURL = try await server.start()
        defer { Task { await server.shutdown() } }
        server.setResponseDelay(milliseconds: 200)
        let fixture = DrafterFixture(prefix: "v2-specdec/gemma4-nonblocking/v1")
        server.setFiles(try fixture.served())
        let root = makeTempStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = SpecDecResolver(storeRoot: root, cdnBaseURL: baseURL.absoluteString)
        let model = try makePinnedModel(id: "gemma-4", fixture: fixture)

        let started = ContinuousClock.now
        let cold = await resolver.resolve(model: model, allowDownload: true)
        let elapsed = ContinuousClock.now - started
        #expect(cold.reason == .artifactNotCached)
        #expect(elapsed < .milliseconds(100), "target load waited for optional artifact network")

        let prefetched = await resolver.prefetch(model: model)
        #expect(prefetched.artifact != nil)
    }

    @Test("conflicting trust references never share an in-flight verdict")
    func conflictingReferencesAreIsolated() async throws {
        let server = SpecDecFileServer()
        let baseURL = try await server.start()
        defer { Task { await server.shutdown() } }
        let fixture = DrafterFixture(prefix: "v2-specdec/gemma4-conflicting/v1")
        server.setFiles(try fixture.served())
        let root = makeTempStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = SpecDecResolver(storeRoot: root, cdnBaseURL: baseURL.absoluteString)
        let good = try makePinnedModel(id: "gemma-4-good", fixture: fixture)
        let bad = makeTrustedModel(
            id: "gemma-4-bad", prefix: fixture.prefix,
            manifestData: try fixture.manifestData(),
            totalSizeBytes: fixture.manifest.totalSizeBytes,
            fileCount: fixture.manifest.fileCount,
            configSHA256: sha256Hex(fixture.configBytes), revision: "v1",
            manifestSHA256: String(repeating: "f", count: 64))

        async let goodResult = resolver.prefetch(model: good)
        async let badResult = resolver.prefetch(model: bad)
        let results = await (goodResult, badResult)
        #expect(results.0.artifact != nil)
        #expect(results.1.artifact == nil)
        #expect(results.1.reason == .manifestDigestMismatch)
        #expect(server.requestedPaths().filter { $0.hasSuffix("manifest.json") }.count == 2)
    }

    @Test("no-download policy never waits on an in-flight downloading policy")
    func conflictingPoliciesAreIsolated() async throws {
        let server = SpecDecFileServer()
        let baseURL = try await server.start()
        defer { Task { await server.shutdown() } }
        server.setResponseDelay(milliseconds: 200)
        let fixture = DrafterFixture(prefix: "v2-specdec/gemma4-policy/v1")
        server.setFiles(try fixture.served())
        let root = makeTempStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = SpecDecResolver(storeRoot: root, cdnBaseURL: baseURL.absoluteString)
        let model = try makePinnedModel(id: "gemma-4", fixture: fixture)

        async let prefetch = resolver.prefetch(model: model)
        try await Task.sleep(nanoseconds: 20_000_000)
        let started = ContinuousClock.now
        let noDownload = await resolver.resolve(model: model, allowDownload: false)
        #expect(ContinuousClock.now - started < .milliseconds(100))
        #expect(noDownload.reason == .artifactNotCached)
        let prefetched = await prefetch
        #expect(prefetched.artifact != nil)
    }

    @Test("prefetch deadline cancels the transfer and removes staging")
    func prefetchDeadlineOwnsCancellation() async throws {
        let server = SpecDecFileServer()
        let baseURL = try await server.start()
        defer { Task { await server.shutdown() } }
        server.setResponseDelay(milliseconds: 500)
        let fixture = DrafterFixture(prefix: "v2-specdec/gemma4-timeout/v1")
        server.setFiles(try fixture.served())
        let root = makeTempStoreRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = SpecDecResolver(
            storeRoot: root, cdnBaseURL: baseURL.absoluteString,
            prefetchTimeout: .milliseconds(50))
        let model = try makePinnedModel(id: "gemma-4", fixture: fixture)

        let started = ContinuousClock.now
        let result = await resolver.prefetch(model: model)
        #expect(ContinuousClock.now - started < .milliseconds(300))
        #expect(result.artifact == nil)
        #expect(result.reason == .fileDownloadFailed)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        #expect(!contents.contains { $0.lastPathComponent.hasPrefix(".staging-") })
    }
}
