import Crypto
import Foundation
import Testing
@testable import ProviderCore
import ProviderCoreFoundation

private final class AssistantHFProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var data: Data
        var status = 200
        var failure: URLError.Code?
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func reset(_ replies: [String: Reply]) {
        lock.withLock { self.replies = replies; requests = [] }
    }
    static func captured() -> [URLRequest] { lock.withLock { requests } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.lock.withLock {
            Self.requests.append(request)
            return Self.replies[request.url!.absoluteString]
                ?? Reply(data: Data(), status: 404)
        }
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(reply.data.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Pinned assistant Hugging Face downloads", .serialized)
struct SpecDecHuggingFaceTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prefix = "v2/assistant/immutable"
        let revision = String(repeating: "a", count: 40)
        let config = Data(#"{"model_type":"gemma4_assistant"}"#.utf8)
        let weight = Data("verified assistant weight".utf8)
        let manifestData: Data

        init() throws {
            let files = [("config.json", config, "config"), ("model.safetensors", weight, "weight")]
            var aggregate = SHA256()
            for file in files {
                aggregate.update(data: Data(SHA256.hash(data: file.1)))
            }
            let manifest = ModelManifest(schemaVersion: 1, modelID: "test/assistant",
                version: revision, r2Prefix: prefix,
                aggregateSHA256: aggregate.finalize().map { String(format: "%02x", $0) }.joined(),
                totalSizeBytes: Int64(config.count + weight.count), fileCount: files.count,
                files: files.map { ManifestFile(path: $0.0, sizeBytes: Int64($0.1.count),
                    sha256: Self.digest($0.1), role: $0.2) }, createdAt: Date(timeIntervalSince1970: 0))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            manifestData = try encoder.encode(manifest)
        }

        static func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        var locator: JSONValue {
            .object([("repo_id", .string("test/assistant")), ("revision", .string(revision))])
        }
        func model(locator: JSONValue?, manifestDigest: String? = nil) -> CatalogModel {
            var pairs: [(String, JSONValue)] = [
                ("r2_prefix", .string(prefix)),
                ("manifest_sha256", .string(manifestDigest ?? Self.digest(manifestData))),
                ("config_sha256", .string(Self.digest(config))),
                ("revision", .string(revision)),
                ("total_size_bytes", .int(Int64(config.count + weight.count))),
                ("file_count", .int(2)), ("max_file_count", .int(2)),
                ("allowed_file_types", .array([.string("config"), .string("weight")]))
            ]
            if let locator { pairs.append(("hugging_face_artifact", locator)) }
            return CatalogModel(id: "target", s3Name: "unused", displayName: "Target",
                sizeGb: 1, metadata: ["spec_dec": .object(pairs)])
        }
        func hf(_ file: String) -> String { "https://huggingface.co/test/assistant/resolve/\(revision)/\(file)" }
        func r2(_ file: String) -> String { "https://assistant-r2.test/\(prefix)/\(file)" }
        var replies: [String: AssistantHFProtocol.Reply] {
            [r2("manifest.json"): .init(data: manifestData),
             r2("config.json"): .init(data: config), r2("model.safetensors"): .init(data: weight),
             hf("config.json"): .init(data: config), hf("model.safetensors"): .init(data: weight)]
        }
        func resolver() -> SpecDecResolver {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [AssistantHFProtocol.self]
            return SpecDecResolver(storeRoot: root, cdnBaseURL: "https://assistant-r2.test",
                urlSession: URLSession(configuration: configuration))
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("assistant files prefer HF and verified local reuse is offline")
    func prefersPinnedHFAndReusesVerifiedPublication() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        AssistantHFProtocol.reset(fixture.replies)
        let model = fixture.model(locator: fixture.locator)
        let resolver = fixture.resolver()
        let result = await resolver.prefetch(model: model)
        let artifact = try #require(result.artifact)
        #expect(try Data(contentsOf: artifact.directory.appendingPathComponent("config.json")) == fixture.config)
        #expect(try Data(contentsOf: artifact.directory.appendingPathComponent("model.safetensors")) == fixture.weight)
        #expect(artifact.catalogReference?.huggingFaceArtifact?.revision == fixture.revision)
        let requests = AssistantHFProtocol.captured()
        #expect(requests.map { $0.url!.absoluteString } == [fixture.r2("manifest.json"),
            fixture.hf("config.json"), fixture.hf("model.safetensors")])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        AssistantHFProtocol.reset([:])
        #expect(await resolver.resolve(model: model, allowDownload: false).artifact != nil)
        #expect(AssistantHFProtocol.captured().isEmpty)
    }

    @Test("an unavailable or corrupt HF shard falls back to verified R2", arguments: ["missing", "offline", "corrupt"])
    func verifiedFallback(reason: String) async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        var replies = fixture.replies
        replies[fixture.hf("model.safetensors")] = switch reason {
        case "missing": .init(data: Data(), status: 404)
        case "offline": .init(data: Data(), failure: .networkConnectionLost)
        default: .init(data: Data(repeating: 0, count: fixture.weight.count))
        }
        AssistantHFProtocol.reset(replies)
        let result = await fixture.resolver().prefetch(model: fixture.model(locator: fixture.locator))
        let artifact = try #require(result.artifact)
        #expect(try Data(contentsOf: artifact.directory.appendingPathComponent("model.safetensors")) == fixture.weight)
        let requests = AssistantHFProtocol.captured()
        #expect(requests.map { $0.url!.absoluteString } == [fixture.r2("manifest.json"),
            fixture.hf("config.json"), fixture.hf("model.safetensors"), fixture.r2("model.safetensors")])
        #expect(requests.last?.value(forHTTPHeaderField: "Range") == nil)
    }

    @Test("HF cancellation does not start R2 or publish partial bytes")
    func cancellationDoesNotFallback() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        var replies = fixture.replies
        replies[fixture.hf("config.json")] = .init(data: Data(), failure: .cancelled)
        AssistantHFProtocol.reset(replies)
        let result = await fixture.resolver().prefetch(model: fixture.model(locator: fixture.locator))
        #expect(result.artifact == nil)
        #expect(AssistantHFProtocol.captured().map { $0.url!.absoluteString } == [
            fixture.r2("manifest.json"), fixture.hf("config.json")])
        #expect(!FileManager.default.fileExists(atPath:
            SpecDecStore.artifactDirectory(root: fixture.root, r2Prefix: fixture.prefix).path))
    }

    @Test("corruption on both sources publishes no assistant and removes staging")
    func rejectsBothCorruptAndCleansStaging() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        var replies = fixture.replies
        let corrupt = AssistantHFProtocol.Reply(data: Data(repeating: 0, count: fixture.weight.count))
        replies[fixture.hf("model.safetensors")] = corrupt
        replies[fixture.r2("model.safetensors")] = corrupt
        AssistantHFProtocol.reset(replies)
        let result = await fixture.resolver().prefetch(model: fixture.model(locator: fixture.locator))
        #expect(result.artifact == nil)
        let requests = AssistantHFProtocol.captured().map { $0.url!.absoluteString }
        #expect(requests.contains(fixture.hf("model.safetensors")))
        #expect(requests.contains(fixture.r2("model.safetensors")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
    }

    @Test("missing or null assistant source metadata preserves R2-only fetching", arguments: [false, true])
    func legacyMetadata(explicitNull: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        AssistantHFProtocol.reset(fixture.replies)
        let result = await fixture.resolver().prefetch(model: fixture.model(locator: explicitNull ? .null : nil))
        #expect(result.artifact != nil)
        #expect(AssistantHFProtocol.captured().map { $0.url!.absoluteString } == [
            fixture.r2("manifest.json"), fixture.r2("config.json"), fixture.r2("model.safetensors")])
    }

    @Test("mutable or malformed assistant locators are rejected before network IO")
    func rejectsInvalidLocators() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        for locator: JSONValue in [
            .object([("repo_id", .string("test/assistant")), ("revision", .string("main"))]),
            .object([("repo_id", .string("test/assistant")), ("revision", .string(fixture.revision)),
                ("path_prefix", .string("../other"))]),
            .object([("repo_id", .string("test/assistant")), ("repo_id", .string("other/assistant")),
                ("revision", .string(fixture.revision))]),
            .string("test/assistant")
        ] {
            AssistantHFProtocol.reset(fixture.replies)
            let result = await fixture.resolver().prefetch(model: fixture.model(locator: locator))
            #expect(result.reason == .metadataMalformed)
            #expect(AssistantHFProtocol.captured().isEmpty)
        }
    }

    @Test("HF never bypasses the pinned registry manifest")
    func rejectsManifestMismatchBeforeFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        AssistantHFProtocol.reset(fixture.replies)
        let result = await fixture.resolver().prefetch(model: fixture.model(
            locator: fixture.locator, manifestDigest: String(repeating: "0", count: 64)))
        #expect(result.artifact == nil)
        #expect(AssistantHFProtocol.captured().map { $0.url!.absoluteString } == [fixture.r2("manifest.json")])
    }
}
