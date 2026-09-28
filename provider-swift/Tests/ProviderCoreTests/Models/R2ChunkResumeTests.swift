import Crypto
import Foundation
import Testing
@testable import ProviderCore
import ProviderCoreFoundation

extension HuggingFaceDownloadTests {
@Suite("R2 chunk orchestration resume", .serialized)
struct R2ChunkResumeTests {
    private let parts = [Data(repeating: 1, count: 64), Data(repeating: 2, count: 8)]
    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private var file: ManifestFile {
        ManifestFile(path: "weights.safetensors", sizeBytes: 72,
            sha256: hash(parts.reduce(Data(), +)), role: "weight",
            r2Chunks: parts.map { ManifestChunk(sizeBytes: Int64($0.count), sha256: hash($0)) })
    }
    private var bodies: [String: Data] {
        Dictionary(uniqueKeysWithValues: parts.enumerated().map {
            (String(format: "/v2/test/weights.safetensors.chunks/%06d.bin", $0.offset), $0.element)
        })
    }
    private func downloader(capacity: Int64? = nil) -> ModelDownloader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModelDownloadURLProtocol.self]
        var result = ModelDownloader(r2CDNURL: "https://r2.test", urlSession: URLSession(configuration: config))
        if let capacity {
            result.capacityCheck = { _, required in
                guard required <= capacity else {
                    throw ModelCatalogError.downloadFailed("test disk has \(capacity) bytes; needs \(required)")
                }
            }
        }
        return result
    }
    private func fixture() -> (model: CatalogModel, manifest: ModelManifest) {
        let id = "test-chunk-resume/\(UUID().uuidString)"
        let aggregate = hash(Data(SHA256.hash(data: parts.reduce(Data(), +))))
        return (
            CatalogModel(id: id, s3Name: "v2/test", displayName: "Test", sizeGb: 0,
                r2Prefix: "v2/test", aggregateSHA256: aggregate),
            ModelManifest(schemaVersion: 1, modelID: id, version: "v1", r2Prefix: "v2/test",
                aggregateSHA256: aggregate, totalSizeBytes: file.sizeBytes, fileCount: 1,
                files: [file], createdAt: Date()))
    }
    private func staging(_ id: String, prefetch: Bool = false) -> URL {
        ModelDownloader.cacheModelDirectory(for: id).appendingPathComponent("snapshots")
            .appendingPathComponent(prefetch ? ".prefetch-staging-v2__test" : ModelDownloader.localStagingDirName(r2Prefix: "v2/test"))
    }
    private func transfer(_ id: String, prefetch: Bool = false) -> URL {
        staging(id, prefetch: prefetch).appendingPathComponent(file.path).appendingPathExtension("r2-transfer")
    }
    private func run(_ downloader: ModelDownloader, model: CatalogModel, manifest: ModelManifest, prefetch: Bool) async throws {
        if prefetch {
            try await downloader.prefetch(model: model, manifest: manifest)
        } else {
            try await downloader.downloadManifestModel(model: model, manifest: manifest, onProgress: nil)
        }
    }

    @Test("foreground failure preserves verified chunks and retries only the missing suffix", arguments: [false, true])
    func foregroundFailure(cancelled: Bool) async throws {
        let (model, manifest) = fixture()
        defer { try? FileManager.default.removeItem(at: ModelDownloader.cacheModelDirectory(for: model.id)) }
        ModelDownloadURLProtocol.reset(bodies: bodies,
            pathFailures: ["/v2/test/weights.safetensors.chunks/000001.bin": cancelled ? .cancelled : .networkConnectionLost])
        await #expect(throws: (any Error).self) {
            try await run(downloader(), model: model, manifest: manifest, prefetch: false)
        }
        #expect(try Data(contentsOf: transfer(model.id).appendingPathComponent("assembled")) == parts[0])
        #expect(!FileManager.default.fileExists(atPath: ModelDownloader.cacheSnapshotDirectory(for: model.id).path))
        ModelDownloadURLProtocol.reset(bodies: bodies)
        // Enough for the final 8 bytes plus its 8-byte scratch, but not 72 bytes.
        try await run(downloader(capacity: 16), model: model, manifest: manifest, prefetch: false)
        #expect(ModelDownloadURLProtocol.captured().map { $0.url!.lastPathComponent } == ["000001.bin"])
        #expect(try Data(contentsOf: ModelDownloader.cacheSnapshotDirectory(for: model.id).appendingPathComponent(file.path)) == parts.reduce(Data(), +))
    }

    @Test("foreground and prefetch admit verified-prefix resumes on a tight disk", arguments: [false, true])
    func tightDisk(prefetch: Bool) async throws {
        let (model, manifest) = fixture()
        defer { try? FileManager.default.removeItem(at: ModelDownloader.cacheModelDirectory(for: model.id)) }
        try FileManager.default.createDirectory(at: transfer(model.id, prefetch: prefetch), withIntermediateDirectories: true)
        try parts[0].write(to: transfer(model.id, prefetch: prefetch).appendingPathComponent("assembled"))
        ModelDownloadURLProtocol.reset(bodies: bodies)
        try await run(downloader(capacity: 16), model: model, manifest: manifest, prefetch: prefetch)
        #expect(ModelDownloadURLProtocol.captured().map { $0.url!.lastPathComponent } == ["000001.bin"])
    }

    @Test("unverified prefixes do not earn disk credit", arguments: [false, true])
    func corruptPrefix(prefetch: Bool) async throws {
        let (model, manifest) = fixture()
        defer { try? FileManager.default.removeItem(at: ModelDownloader.cacheModelDirectory(for: model.id)) }
        try FileManager.default.createDirectory(at: transfer(model.id, prefetch: prefetch), withIntermediateDirectories: true)
        try Data(repeating: 0, count: 64).write(to: transfer(model.id, prefetch: prefetch).appendingPathComponent("assembled"))
        ModelDownloadURLProtocol.reset(bodies: bodies)
        await #expect(throws: (any Error).self) {
            try await run(downloader(capacity: 16), model: model, manifest: manifest, prefetch: prefetch)
        }
        #expect(ModelDownloadURLProtocol.captured().isEmpty)
    }

    @Test("completed assembly publishes with no additional space or network", arguments: [false, true])
    func completedAssembly(prefetch: Bool) async throws {
        let (model, manifest) = fixture()
        defer { try? FileManager.default.removeItem(at: ModelDownloader.cacheModelDirectory(for: model.id)) }
        try FileManager.default.createDirectory(at: transfer(model.id, prefetch: prefetch), withIntermediateDirectories: true)
        try parts.reduce(Data(), +).write(to: transfer(model.id, prefetch: prefetch).appendingPathComponent("assembled"))
        ModelDownloadURLProtocol.reset(bodies: [:])
        try await run(downloader(capacity: 0), model: model, manifest: manifest, prefetch: prefetch)
        #expect(ModelDownloadURLProtocol.captured().isEmpty)
        #expect(try Data(contentsOf: ModelDownloader.cacheSnapshotDirectory(for: model.id).appendingPathComponent(file.path)) == parts.reduce(Data(), +))
    }

    @Test("foreground cancellation preserves a partial first chunk before any assembly")
    func partialFirstChunk() async throws {
        let (model, manifest) = fixture()
        defer { try? FileManager.default.removeItem(at: ModelDownloader.cacheModelDirectory(for: model.id)) }
        try FileManager.default.createDirectory(at: transfer(model.id), withIntermediateDirectories: true)
        let partial = transfer(model.id).appendingPathComponent("chunk.bin.part")
        try parts[0].prefix(4).write(to: partial)
        ModelDownloadURLProtocol.reset(bodies: bodies,
            pathFailures: ["/v2/test/weights.safetensors.chunks/000000.bin": .cancelled])
        await #expect(throws: (any Error).self) {
            try await run(downloader(), model: model, manifest: manifest, prefetch: false)
        }
        #expect(try Data(contentsOf: partial) == parts[0].prefix(4))
        ModelDownloadURLProtocol.reset(bodies: bodies)
        try await run(downloader(), model: model, manifest: manifest, prefetch: false)
        #expect(ModelDownloadURLProtocol.captured().first?.value(forHTTPHeaderField: "Range") == "bytes=4-")
    }

    @Test("scratch reservation follows concurrency and HF cannot credit a chunk assembly")
    func capacityAccounting() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let jobs = (0..<3).map { index in
            (file: file, destination: dir.appendingPathComponent("\(index).safetensors"), url: "https://r2.test/unused")
        }
        for job in jobs {
            let transfer = job.destination.appendingPathExtension("r2-transfer")
            try FileManager.default.createDirectory(at: transfer, withIntermediateDirectories: true)
            try parts[0].write(to: transfer.appendingPathComponent("assembled"))
        }
        let d = downloader()
        #expect(try d.manifestCapacityRequired(jobs: jobs, alreadyValid: [false, false, false],
            huggingFaceArtifact: nil, concurrency: 1) == 32)
        #expect(try d.manifestCapacityRequired(jobs: jobs, alreadyValid: [false, false, false],
            huggingFaceArtifact: nil, concurrency: 2) == 40)
        #expect(try d.manifestCapacityRequired(jobs: jobs, alreadyValid: [true, false, false],
            huggingFaceArtifact: nil, concurrency: 4) == 32)
        let hf = HuggingFaceArtifact(repoID: "test/model", revision: String(repeating: "a", count: 40))
        #expect(try d.manifestCapacityRequired(jobs: jobs, alreadyValid: [false, false, false],
            huggingFaceArtifact: hf, concurrency: 1) >= 216)
    }
}
}
