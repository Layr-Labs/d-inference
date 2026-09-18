import Crypto
import Foundation
import Testing
@testable import ProviderCore
import ProviderCoreFoundation

private final class HFDownloadProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bodies: [String: Data] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var failure: URLError.Code?
    private static let lock = NSLock()

    static func reset(bodies: [String: Data], failure: URLError.Code? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.bodies = bodies; self.failure = failure; requests = []
    }

    static func captured() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.lock()
        Self.requests.append(request)
        let body = Self.bodies[url.host!]
        let failure = url.host == "huggingface.co" ? Self.failure : nil
        Self.lock.unlock()
        if let failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        var status = body == nil ? 404 : 200
        var payload = body
        var headers = ["Content-Length": "\(body?.count ?? 0)"]
        if let body, let range = request.value(forHTTPHeaderField: "Range"),
           range.hasPrefix("bytes="), let offset = Int(range.dropFirst(6).dropLast()),
           offset < body.count {
            payload = Data(body.dropFirst(offset))
            status = 206
            headers["Content-Range"] = "bytes \(offset)-\(body.count - 1)/\(body.count)"
            headers["Content-Length"] = "\(body.count - offset)"
        }
        let response = HTTPURLResponse(url: url, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let payload { client?.urlProtocol(self, didLoad: payload) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Hugging Face verified downloads", .serialized)
struct HuggingFaceDownloadTests {
    private let revision = String(repeating: "a", count: 40)
    private let bytes = Data("registered model bytes".utf8)
    private var artifact: HuggingFaceArtifact {
        HuggingFaceArtifact(repoID: "EigenLabs/test", revision: revision, pathPrefix: "mlx")
    }
    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func downloader() -> ModelDownloader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HFDownloadProtocol.self]
        return ModelDownloader(r2CDNURL: "https://r2.test", urlSession: URLSession(configuration: config))
    }
    private func job(_ destination: URL) -> (file: ManifestFile, destination: URL, url: String) {
        (ManifestFile(path: "weights/model.safetensors", sizeBytes: Int64(bytes.count),
            sha256: digest(bytes), role: "weight"), destination, "https://r2.test/v2/test/model.safetensors")
    }

    @Test("pinned URLs escape paths and reject mutable or unsafe artifact locators")
    func urls() throws {
        let url = try artifact.downloadURL(for: "weights/file #?%.safetensors")
        #expect(url.absoluteString == "https://huggingface.co/EigenLabs/test/resolve/\(revision)/mlx/weights/file%20%23%3F%25.safetensors")
        for invalid in [
            HuggingFaceArtifact(repoID: "EigenLabs/test", revision: "main"),
            HuggingFaceArtifact(repoID: "https://evil.test/repo", revision: revision),
            HuggingFaceArtifact(repoID: "org//repo", revision: revision),
            HuggingFaceArtifact(repoID: "org/repo", revision: revision, pathPrefix: "../weights"),
            HuggingFaceArtifact(repoID: "org/repo", revision: revision, pathPrefix: "weights/"),
        ] {
            #expect(throws: (any Error).self) { try invalid.downloadURL(for: "config.json") }
        }
        #expect(throws: (any Error).self) { try artifact.downloadURL(for: "../config.json") }
    }

    @Test("catalog decodes optional artifact independently from upstream identity")
    func catalogDecoding() throws {
        let json = """
        {"id":"test","s3_name":"v2/test/v1","display_name":"Test","model_type":"text","size_gb":1,
         "hugging_face_id":"upstream/base","hugging_face_artifact":{
         "repo_id":"EigenLabs/test","revision":"\(revision)","path_prefix":"mlx"}}
        """
        let model = try JSONDecoder().decode(CatalogModel.self, from: Data(json.utf8))
        #expect(model.huggingFaceArtifact == artifact)
        let encoded = try JSONEncoder().encode(model)
        #expect(try JSONDecoder().decode(CatalogModel.self, from: encoded).huggingFaceArtifact == artifact)
    }

    @Test("HF resumes a saved prefix with Range and verifies the completed file")
    func resume() async throws {
        HFDownloadProtocol.reset(bodies: ["huggingface.co": bytes])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent("model.safetensors")
        try Data(bytes.prefix(4)).write(to: destination.appendingPathExtension("part"))
        try await downloader().downloadManifestFileWithResume(job(destination), huggingFaceArtifact: artifact)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(HFDownloadProtocol.captured().count == 1)
        #expect(HFDownloadProtocol.captured().first?.value(forHTTPHeaderField: "Range") == "bytes=4-")
    }

    @Test("HF is preferred and verified without touching R2")
    func prefersHF() async throws {
        HFDownloadProtocol.reset(bodies: ["huggingface.co": bytes])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("model.safetensors")
        try await downloader().downloadManifestFileWithResume(job(destination), huggingFaceArtifact: artifact)
        #expect(try Data(contentsOf: destination) == bytes)
        let requests = HFDownloadProtocol.captured()
        #expect(requests.count == 1)
        #expect(requests.first?.url?.host == "huggingface.co")
        #expect(requests.first?.timeoutInterval == 30)
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("HF missing, offline, stalled, or corrupt falls back to verified R2", arguments: ["missing", "offline", "timeout", "corrupt"])
    func fallback(reason: String) async throws {
        var bodies = ["r2.test": bytes]
        if reason == "corrupt" { bodies["huggingface.co"] = Data(repeating: 0, count: bytes.count) }
        let failure: URLError.Code? = reason == "offline" ? .networkConnectionLost : (reason == "timeout" ? .timedOut : nil)
        HFDownloadProtocol.reset(bodies: bodies, failure: failure)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent("model.safetensors")
        // A corrupt saved prefix must not leak into the R2 request after HF fails.
        try Data([0, 1]).write(to: destination.appendingPathExtension("part"))
        try await downloader().downloadManifestFileWithResume(job(destination), huggingFaceArtifact: artifact)
        #expect(try Data(contentsOf: destination) == bytes)
        let requests = HFDownloadProtocol.captured()
        #expect(requests.map { $0.url!.host! } == ["huggingface.co", "r2.test"])
        #expect(requests.last?.value(forHTTPHeaderField: "Range") == nil)
    }

    @Test("cancellation does not retry on R2 or delete resumable bytes")
    func cancellation() async throws {
        HFDownloadProtocol.reset(bodies: ["r2.test": bytes], failure: .cancelled)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent("model.safetensors")
        let partial = destination.appendingPathExtension("part")
        try Data([1, 2]).write(to: partial)
        await #expect(throws: (any Error).self) {
            try await downloader().downloadManifestFileWithResume(job(destination), huggingFaceArtifact: artifact)
        }
        #expect(HFDownloadProtocol.captured().count == 1)
        #expect(try Data(contentsOf: partial) == Data([1, 2]))
    }

    @Test("legacy entry downloads only from R2")
    func legacy() async throws {
        HFDownloadProtocol.reset(bodies: ["r2.test": bytes])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await downloader().downloadManifestFileWithResume(job(dir.appendingPathComponent("model.safetensors")))
        #expect(HFDownloadProtocol.captured().map { $0.url!.host! } == ["r2.test"])
    }

    @Test("foreground and prefetch publish only verified HF bytes", arguments: [false, true])
    func publication(prefetch: Bool) async throws {
        HFDownloadProtocol.reset(bodies: ["huggingface.co": bytes])
        let id = "test-hf/\(UUID().uuidString)"
        let modelDir = ModelDownloader.cacheModelDirectory(for: id)
        defer { try? FileManager.default.removeItem(at: modelDir) }
        let file = job(modelDir).file
        let rawDigest = Data(SHA256.hash(data: bytes))
        let aggregate = digest(rawDigest)
        let model = CatalogModel(id: id, s3Name: "v2/test/v1", displayName: "Test", sizeGb: 0,
            r2Prefix: "v2/test/v1", huggingFaceArtifact: artifact, aggregateSHA256: aggregate)
        let manifest = ModelManifest(schemaVersion: 1, modelID: id, version: "v1", r2Prefix: "v2/test/v1",
            aggregateSHA256: aggregate, totalSizeBytes: Int64(bytes.count), fileCount: 1, files: [file], createdAt: Date())
        if prefetch {
            try await downloader().prefetch(model: model, manifest: manifest)
        } else {
            try await downloader().downloadManifestModel(model: model, manifest: manifest, onProgress: nil)
        }
        let snapshot = ModelDownloader.cacheSnapshotDirectory(for: id)
        #expect(try Data(contentsOf: snapshot.appendingPathComponent(file.path)) == bytes)
        #expect(try String(contentsOf: modelDir.appendingPathComponent("refs/main"), encoding: .utf8) == "local")
        #expect(HFDownloadProtocol.captured().map { $0.url!.host! } == ["huggingface.co"])
    }

    @Test("corruption on both sources never publishes a snapshot")
    func rejectsBothCorrupt() async throws {
        HFDownloadProtocol.reset(bodies: ["huggingface.co": Data([0]), "r2.test": Data([0])])
        let id = "test-hf/\(UUID().uuidString)"
        let modelDir = ModelDownloader.cacheModelDirectory(for: id)
        defer { try? FileManager.default.removeItem(at: modelDir) }
        let file = job(modelDir).file
        let aggregate = digest(Data(SHA256.hash(data: bytes)))
        let model = CatalogModel(id: id, s3Name: "v2/test/v1", displayName: "Test", sizeGb: 0,
            r2Prefix: "v2/test/v1", huggingFaceArtifact: artifact, aggregateSHA256: aggregate)
        let manifest = ModelManifest(schemaVersion: 1, modelID: id, version: "v1", r2Prefix: "v2/test/v1",
            aggregateSHA256: aggregate, totalSizeBytes: Int64(bytes.count), fileCount: 1, files: [file], createdAt: Date())
        await #expect(throws: (any Error).self) { try await downloader().prefetch(model: model, manifest: manifest) }
        #expect(!FileManager.default.fileExists(atPath: modelDir.appendingPathComponent("refs/main").path))
        #expect(!FileManager.default.fileExists(atPath: ModelDownloader.cacheSnapshotDirectory(for: id).path))
    }
}
