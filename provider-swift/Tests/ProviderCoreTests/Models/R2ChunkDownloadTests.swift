import Crypto
import Foundation
import Testing
@testable import ProviderCore
import ProviderCoreFoundation

extension HuggingFaceDownloadTests {
@Suite("R2 transport chunks", .serialized)
struct R2ChunkDownloadTests {
    private let parts = [Data("first chunk".utf8), Data("second chunk".utf8)]
    private func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private var file: ManifestFile {
        ManifestFile(path: "weights.safetensors", sizeBytes: Int64(parts.reduce(0) { $0 + $1.count }),
            sha256: hash(parts.reduce(Data(), +)), role: "weight",
            r2Chunks: parts.map { ManifestChunk(sizeBytes: Int64($0.count), sha256: hash($0)) })
    }
    private var bodies: [String: Data] {
        Dictionary(uniqueKeysWithValues: parts.enumerated().map {
            (String(format: "/v2/test/weights.safetensors.chunks/%06d.bin", $0.offset), $0.element)
        })
    }
    private func downloader() -> ModelDownloader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModelDownloadURLProtocol.self]
        return ModelDownloader(urlSession: URLSession(configuration: config))
    }
    private func job(_ directory: URL, file override: ManifestFile? = nil) -> (file: ManifestFile, destination: URL, url: String) {
        (override ?? file, directory.appendingPathComponent(file.path), "https://r2.test/v2/test/weights.safetensors")
    }

    @Test("chunked catalog entries exclude providers without reconstruction support")
    func capabilityGate() {
        #expect(!ModelRuntimeRequirements.isEligible(modelID: "test/model", catalogRequirements: [.r2Chunks], available: []))
        #expect(ModelRuntimeRequirements.isEligible(modelID: "test/model", catalogRequirements: [.r2Chunks], available: [.r2Chunks]))
    }

    @Test("HF failure fetches R2 chunks and reconstructs the exact original")
    func fallback() async throws {
        ModelDownloadURLProtocol.reset(bodies: bodies)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await downloader().downloadManifestFileWithResume(job(dir), huggingFaceArtifact:
            HuggingFaceArtifact(repoID: "test/model", revision: String(repeating: "a", count: 40)))
        #expect(try Data(contentsOf: job(dir).destination) == parts.reduce(Data(), +))
        let requests = ModelDownloadURLProtocol.captured()
        #expect(requests.count == 3)
        #expect(requests.first?.url?.host == "huggingface.co")
        #expect(requests.dropFirst().allSatisfy { $0.url!.path.contains(".chunks/") })
        #expect(!FileManager.default.fileExists(atPath: job(dir).destination.appendingPathExtension("r2-transfer").path))
    }

    @Test("restart verifies the prefix and repairs interrupted or corrupt assembly", arguments: [false, true])
    func resume(prefixCorrupt: Bool) async throws {
        ModelDownloadURLProtocol.reset(bodies: bodies,
            pathFailures: ["/v2/test/weights.safetensors.chunks/000001.bin": .cancelled])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: (any Error).self) {
            try await downloader().downloadManifestFileWithResume(job(dir))
        }
        #expect(!FileManager.default.fileExists(atPath: job(dir).destination.path))
        let assembled = job(dir).destination.appendingPathExtension("r2-transfer").appendingPathComponent("assembled")
        #expect(try Data(contentsOf: assembled) == parts[0])
        // Simulate a crash midway through appending the next verified chunk.
        let handle = try FileHandle(forWritingTo: assembled)
        if prefixCorrupt { try handle.write(contentsOf: Data([0])) }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("torn append".utf8))
        try handle.close()
        ModelDownloadURLProtocol.reset(bodies: bodies)
        try await downloader().downloadManifestFileWithResume(job(dir))
        #expect(try Data(contentsOf: job(dir).destination) == parts.reduce(Data(), +))
        #expect(ModelDownloadURLProtocol.captured().map { $0.url!.lastPathComponent } ==
            (prefixCorrupt ? ["000000.bin", "000001.bin"] : ["000001.bin"]))
    }

    @Test("valid HF bytes avoid chunk requests even with a chunked manifest")
    func prefersHFWithChunks() async throws {
        ModelDownloadURLProtocol.reset(bodies: ["huggingface.co": parts.reduce(Data(), +)])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await downloader().downloadManifestFileWithResume(job(dir), huggingFaceArtifact:
            HuggingFaceArtifact(repoID: "test/model", revision: String(repeating: "a", count: 40)))
        #expect(try Data(contentsOf: job(dir).destination) == parts.reduce(Data(), +))
        #expect(ModelDownloadURLProtocol.captured().count == 1)
    }

    @Test("corrupt R2 chunk is rejected and the model is never published")
    func corruptChunk() async throws {
        var corrupt = bodies
        corrupt["/v2/test/weights.safetensors.chunks/000000.bin"] = Data(repeating: 0, count: parts[0].count)
        ModelDownloadURLProtocol.reset(bodies: corrupt)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: (any Error).self) {
            try await downloader().downloadManifestFileWithResume(job(dir))
        }
        #expect(!FileManager.default.fileExists(atPath: job(dir).destination.path))
        #expect(ModelDownloadURLProtocol.captured().count == 3)
    }

    @Test("foreground and background publish reconstructed model files", arguments: [false, true])
    func publish(prefetch: Bool) async throws {
        ModelDownloadURLProtocol.reset(bodies: bodies)
        let id = "test-chunks/\(UUID().uuidString)"
        let modelRoot = ModelDownloader.cacheModelDirectory(for: id)
        defer { try? FileManager.default.removeItem(at: modelRoot) }
        let aggregate = hash(Data(SHA256.hash(data: parts.reduce(Data(), +))))
        let model = CatalogModel(id: id, s3Name: "v2/test", displayName: "Test", sizeGb: 0,
            r2Prefix: "v2/test", aggregateSHA256: aggregate)
        let manifest = ModelManifest(schemaVersion: 1, modelID: id, version: "v1", r2Prefix: "v2/test",
            aggregateSHA256: aggregate, totalSizeBytes: file.sizeBytes, fileCount: 1,
            files: [file], createdAt: Date())
        if prefetch {
            try await downloader().prefetch(model: model, manifest: manifest)
        } else {
            try await downloader().downloadManifestModel(model: model, manifest: manifest, onProgress: nil)
        }
        let snapshot = ModelDownloader.cacheSnapshotDirectory(for: id)
        #expect(try Data(contentsOf: snapshot.appendingPathComponent(file.path)) == parts.reduce(Data(), +))
        #expect(try FileManager.default.contentsOfDirectory(atPath: snapshot.path) == [file.path])
    }

    @Test("verified chunks cannot bypass the original file checksum")
    func wrongAssemblyHash() async throws {
        ModelDownloadURLProtocol.reset(bodies: bodies)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wrong = ManifestFile(path: file.path, sizeBytes: file.sizeBytes,
            sha256: String(repeating: "0", count: 64), role: file.role, r2Chunks: file.r2Chunks)
        await #expect(throws: (any Error).self) {
            try await downloader().downloadManifestFileWithResume(job(dir, file: wrong))
        }
        #expect(!FileManager.default.fileExists(atPath: job(dir).destination.path))
    }

    @Test("malformed or oversized chunks are rejected before network access")
    func invalidChunks() async throws {
        ModelDownloadURLProtocol.reset(bodies: bodies)
        for chunks in [[], [ManifestChunk(sizeBytes: 500_000_000, sha256: hash(parts[0]))],
                       [ManifestChunk(sizeBytes: 1, sha256: hash(parts[0]))]] as [[ManifestChunk]] {
            let bad = ManifestFile(path: file.path, sizeBytes: file.sizeBytes,
                sha256: file.sha256, role: file.role, r2Chunks: chunks)
            await #expect(throws: (any Error).self) {
                try await downloader().downloadManifestFileWithResume(job(URL(fileURLWithPath: "/unused"), file: bad))
            }
        }
        #expect(ModelDownloadURLProtocol.captured().isEmpty)
    }
}
}
