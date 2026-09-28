import Foundation
import Testing
@testable import ProviderCore

private final class ReceiptOfflineURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)) }
    override func stopLoading() {}
}

@Suite("Model artifact receipt recovery", .serialized)
struct ModelArtifactReceiptTests {
    private func manifest(_ f: RevisionActivationFixture) throws -> ModelManifest {
        try #require(ModelDownloader.revisionReceipt(at: f.newDirectory))
    }

    private func receiptURL(_ f: RevisionActivationFixture) -> URL {
        f.newDirectory.appendingPathComponent(".darkbloom-manifest.json")
    }

    private func damageReceipt(_ f: RevisionActivationFixture, kind: String) throws {
        let receipt = receiptURL(f)
        if kind == "valid" { return }
        if kind == "missing" {
            try FileManager.default.removeItem(at: receipt)
        } else if kind == "truncated" {
            try Data("{\"model_id\":".utf8).write(to: receipt)
        } else {
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
            if kind == "wrong-version" {
                json["version"] = "incorrect"
            } else if kind == "wrong-total" {
                json["total_size_bytes"] = -1
            } else if kind == "wrong-count" {
                json["file_count"] = -1
            } else {
                var files = try #require(json["files"] as? [[String: Any]])
                files[0]["path"] = "wrong-config.json"
                json["files"] = files
            }
            try JSONSerialization.data(withJSONObject: json).write(to: receipt)
        }
    }

    /// Exercise each production reuse entry point with networking unavailable.
    /// Download/publish callers own a lease; prefetch/protected preparation take
    /// theirs internally. Receipt recovery must reuse the existing verified bytes.
    private func reuse(_ f: RevisionActivationFixture, manifest: ModelManifest, path: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReceiptOfflineURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let downloader = ModelDownloader(r2CDNURL: "https://offline.test", urlSession: session)
        let model = CatalogModel(id: f.id, s3Name: manifest.r2Prefix, displayName: f.id, sizeGb: 0,
            version: manifest.version, r2Prefix: manifest.r2Prefix, aggregateSHA256: manifest.aggregateSHA256)
        switch path {
        case "prefetch":
            try await downloader.prefetch(model: model, manifest: manifest)
        case "protected":
            let staged = try #require(try await f.loop.protectPreparedModelRevision(
                f.staged.entry, directory: f.newDirectory, manifest: manifest))
            do {
                try await f.loop.beginModelRevisionDrain(staged)
                #expect(try await f.loop.commitModelRevisionIfIdle(staged))
            } catch {
                await f.loop.finishModelRevisionDrain(staged)
                throw error
            }
            await f.loop.finishModelRevisionDrain(staged)
            #expect(await f.loop.pendingModelRevisions().isEmpty)
        default:
            let lease = try await ModelArtifactWriteLease.acquire(modelID: f.id)
            defer { lease.release() }
            if path == "foreground" {
                try await downloader.downloadManifestModel(model: model, manifest: manifest, onProgress: nil)
            } else {
                try ModelDownloader.publishRevision(stagingDir: f.newDirectory.appendingPathComponent("unused-staging"),
                    directory: f.newDirectory, manifest: manifest)
                try ModelDownloader.activateRevision(modelID: f.id, directory: f.newDirectory)
            }
        }
    }

    @Test("all reuse paths repair damaged receipts after fresh byte verification",
        arguments: ["foreground", "prefetch", "publish", "protected"], ["missing", "truncated", "wrong-version", "wrong-layout", "wrong-total", "wrong-count"])
    func repairsReceipt(path: String, damage: String) async throws {
        let f = try await RevisionActivationFixture.make()
        defer { f.clean() }
        let manifest = try manifest(f)
        try damageReceipt(f, kind: damage)
        f.staged.lease.release()
        try await reuse(f, manifest: manifest, path: path)
        let restored = try #require(ModelDownloader.revisionReceipt(at: f.newDirectory))
        #expect(ModelRevisionIdentity(restored) == ModelRevisionIdentity(manifest))
        #expect(restored.fileCount == manifest.fileCount && restored.totalSizeBytes == manifest.totalSizeBytes)
        #expect(ModelDownloader.selectedRevisionMatches(modelID: f.id,
            version: manifest.version, aggregateSHA256: manifest.aggregateSHA256))
        #expect(ModelDownloader.verifiedRevisionExists(at: f.newDirectory, manifest: manifest))
    }

    @Test("reuse preserves valid receipt metadata when the complete stable identity is unchanged",
        arguments: ["foreground", "prefetch", "publish", "protected"])
    func preservesEquivalentReceipt(path: String) async throws {
        let f = try await RevisionActivationFixture.make()
        defer { f.clean() }
        let manifest = try manifest(f)
        let equivalent = ModelManifest(schemaVersion: manifest.schemaVersion, modelID: manifest.modelID,
            version: manifest.version, r2Prefix: manifest.r2Prefix, aggregateSHA256: manifest.aggregateSHA256,
            totalSizeBytes: manifest.totalSizeBytes, fileCount: manifest.fileCount,
            files: manifest.files.reversed(), createdAt: manifest.createdAt.addingTimeInterval(60))
        try ModelDownloader.writeRevisionReceipt(equivalent, at: f.newDirectory)
        let originalReceipt = try Data(contentsOf: receiptURL(f))
        f.staged.lease.release()
        try await reuse(f, manifest: manifest, path: path)
        #expect(try Data(contentsOf: receiptURL(f)) == originalReceipt)
    }

    @Test("corrupt model bytes are never blessed by receipt restoration",
        arguments: ["foreground", "prefetch", "publish", "protected"], ["missing", "truncated", "valid"])
    func corruptWeightsRemainUnblessed(path: String, damage: String) async throws {
        let f = try await RevisionActivationFixture.make()
        defer { f.clean() }
        let manifest = try manifest(f)
        try damageReceipt(f, kind: damage)
        let originalReceipt = try? Data(contentsOf: receiptURL(f))
        try Data("bad".utf8).write(to: f.newDirectory.appendingPathComponent("model.safetensors"))
        f.staged.lease.release()
        await #expect(throws: (any Error).self) { try await reuse(f, manifest: manifest, path: path) }
        #expect((try? Data(contentsOf: receiptURL(f))) == originalReceipt)
        #expect(ModelScanner.resolveLocalPath(modelID: f.id) == f.oldDirectory)
        #expect(await !f.loop.revisionTestDraining(f.id))
        #expect(await f.loop.revisionTestHash(f.id) == f.oldHash)
    }

    @Test("a matching version and hash cannot conceal an invalid receipt", arguments: ["wrong-layout", "wrong-total", "wrong-count"])
    func wrongReceiptCannotSkipReconciliation(damage: String) async throws {
        let f = try await RevisionActivationFixture.make()
        defer { f.clean() }
        let manifest = try manifest(f)
        try ModelDownloader.activateRevision(modelID: f.id, directory: f.newDirectory)
        #expect(ModelDownloader.selectedRevisionMatches(modelID: f.id,
            version: manifest.version, aggregateSHA256: manifest.aggregateSHA256))
        try damageReceipt(f, kind: damage)
        #expect(!ModelDownloader.selectedRevisionMatches(modelID: f.id,
            version: manifest.version, aggregateSHA256: manifest.aggregateSHA256))
    }

    @Test("unmanifested integrity files prevent every snapshot reuse path",
        arguments: ["foreground", "prefetch", "publish", "protected"], ["chat_template.jinja", "adapters/extra.safetensors"])
    func extraIntegrityFilesRejectReuse(path: String, extra: String) async throws {
        let f = try await RevisionActivationFixture.make()
        defer { f.clean() }
        let manifest = try manifest(f)
        let originalReceipt = try Data(contentsOf: receiptURL(f))
        let added = f.newDirectory.appendingPathComponent(extra)
        try FileManager.default.createDirectory(at: added.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{{ messages[0]['content'] }}".utf8).write(to: added)
        #expect(WeightHasher.computeHash(snapshotDir: f.newDirectory) != manifest.aggregateSHA256)
        #expect(!ModelDownloader.verifiedRevisionExists(at: f.newDirectory, manifest: manifest))
        f.staged.lease.release()
        await #expect(throws: (any Error).self) { try await reuse(f, manifest: manifest, path: path) }
        #expect(try Data(contentsOf: receiptURL(f)) == originalReceipt)
        #expect(ModelScanner.resolveLocalPath(modelID: f.id) == f.oldDirectory)
        #expect(await !f.loop.revisionTestDraining(f.id))
        #expect(await f.loop.revisionTestHash(f.id) == f.oldHash)
    }

    @Test("non-runtime files and hidden receipts do not invalidate a snapshot",
        arguments: ["foreground", "prefetch", "publish", "protected"])
    func benignExtraFilesPermitReuse(path: String) async throws {
        let f = try await RevisionActivationFixture.make()
        defer { f.clean() }
        let manifest = try manifest(f)
        try Data("local notes".utf8).write(to: f.newDirectory.appendingPathComponent("README.md"))
        f.staged.lease.release()
        try await reuse(f, manifest: manifest, path: path)
        #expect(ModelDownloader.selectedRevisionMatches(modelID: f.id,
            version: manifest.version, aggregateSHA256: manifest.aggregateSHA256))
    }

    @Test("resumed staging with extra integrity files cannot be published", arguments: ["chat_template.jinja", "adapters/extra.safetensors"])
    func extraStagingFilesRejectPublication(extra: String) async throws {
        let f = try await RevisionActivationFixture.make()
        defer { f.clean() }
        let manifest = try manifest(f)
        let staging = f.newDirectory.deletingLastPathComponent().appendingPathComponent(".staging-extra", isDirectory: true)
        try FileManager.default.moveItem(at: f.newDirectory, to: staging)
        let added = staging.appendingPathComponent(extra)
        try FileManager.default.createDirectory(at: added.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unmanifested".utf8).write(to: added)
        let model = CatalogModel(id: f.id, s3Name: manifest.r2Prefix, displayName: f.id, sizeGb: 0,
            version: manifest.version, r2Prefix: manifest.r2Prefix, aggregateSHA256: manifest.aggregateSHA256)
        let downloader = ModelDownloader()
        #expect(throws: (any Error).self) {
            try downloader.finalizeStagedManifest(model: model, manifest: manifest,
                jobs: downloader.manifestJobs(manifest, stagingDir: staging), stagingDir: staging,
                cacheDir: f.newDirectory)
        }
        #expect(!FileManager.default.fileExists(atPath: f.newDirectory.path))
        #expect(ModelScanner.resolveLocalPath(modelID: f.id) == f.oldDirectory)
    }
}
