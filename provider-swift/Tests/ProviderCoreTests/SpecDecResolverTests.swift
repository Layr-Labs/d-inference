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

    func setFiles(_ files: [String: Data]) {
        lock.lock(); self.files = files; lock.unlock()
    }

    func requestedPaths() -> [String] {
        lock.lock(); defer { lock.unlock() }; return requested
    }

    func clearRequested() {
        lock.lock(); requested = []; lock.unlock()
    }

    private func record(_ path: String) {
        lock.lock(); requested.append(path); lock.unlock()
    }

    private func body(for path: String) -> Data? {
        lock.lock(); defer { lock.unlock() }; return files[path]
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
            // Junk aggregate: the resolver performs NO aggregate-hash
            // enforcement by design (plan D3) -- per-file SHA-256 only.
            aggregateSHA256: String(repeating: "0", count: 64),
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return [
            "/\(prefix)/manifest.json": try encoder.encode(manifest),
            "/\(prefix)/config.json": configBytes,
            "/\(prefix)/model.safetensors": weightBytes,
        ]
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
        let model = makeModel(id: "gemma-4-26b-qat", specDecPrefix: prefix)

        let dir = await resolver.drafterDirectory(for: model, allowDownload: true)
        let resolved = try #require(dir)

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
        let staging = SpecDecStore.stagingDirectory(root: storeRoot, r2Prefix: prefix)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
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
        let model = makeModel(id: "gemma-4-26b-qat", specDecPrefix: prefix)

        let dir = await resolver.drafterDirectory(for: model, allowDownload: true)
        #expect(dir == nil)
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
        #expect(SpecDecResolver.specDecR2Prefix(for: makeModel(id: "m", specDecPrefix: "p/q")) == "p/q")
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
        let model = makeModel(id: "gemma-4-26b-qat", specDecPrefix: "v2-specdec/missing/v1")

        #expect(await resolver.drafterDirectory(for: model, allowDownload: true) == nil)
        #expect(!FileManager.default.fileExists(
            atPath: SpecDecStore.artifactDirectory(root: storeRoot, r2Prefix: "v2-specdec/missing/v1").path))
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
        let model = makeModel(id: "gemma-4-26b-qat", specDecPrefix: prefix)

        let first = try #require(await resolver.drafterDirectory(for: model, allowDownload: true))
        #expect(!server.requestedPaths().isEmpty)

        server.clearRequested()
        let second = try #require(await resolver.drafterDirectory(for: model, allowDownload: true))
        #expect(second == first)
        #expect(server.requestedPaths().isEmpty, "warm re-resolve must not touch the CDN")

        // allowDownload: false also resolves a verified stored copy.
        let third = try #require(await resolver.drafterDirectory(for: model, allowDownload: false))
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
        let model = makeModel(id: "gemma-4-26b-qat", specDecPrefix: prefix)

        #expect(await resolver.drafterDirectory(for: model, allowDownload: false) == nil)
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
        let qat = makeModel(id: "gemma-4-26b-qat", specDecPrefix: prefix)
        let eightBit = makeModel(id: "gemma-4-26b-8bit", specDecPrefix: prefix)

        let qatDir = try #require(await resolver.drafterDirectory(for: qat, allowDownload: true))
        server.clearRequested()

        let eightBitDir = try #require(await resolver.drafterDirectory(for: eightBit, allowDownload: true))
        #expect(eightBitDir == qatDir, "both builds must resolve to the same stored artifact")
        #expect(server.requestedPaths().isEmpty, "the second build must reuse the first download")
    }
}
