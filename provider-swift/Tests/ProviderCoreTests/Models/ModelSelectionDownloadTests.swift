import Crypto
import Foundation
import Testing
@testable import ProviderCore

private final class SelectionManifestURLProtocol: URLProtocol, @unchecked Sendable {
    private final class Responses: @unchecked Sendable {
        let lock = NSLock()
        var data: [String: Data] = [:]
    }
    private static let responses = Responses()

    static func set(_ data: Data?, url: URL) {
        responses.lock.withLock { responses.data[url.absoluteString] = data }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
            let data = Self.responses.lock.withLock({ Self.responses.data[url.absoluteString] }),
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Selected model verification and download planning", .serialized)
struct ModelSelectionDownloadTests {
    private struct Fixture {
        let id: String
        let model: CatalogModel
        let manifest: ModelManifest
        let staging: URL
        let revision: URL
        let downloader: ModelDownloader
        let session: URLSession
        let manifestURL: URL

        var modelDirectory: URL { ModelDownloader.cacheModelDirectory(for: id) }

        static func make() throws -> Self {
            let id = "test-org/selection-\(UUID().uuidString)"
            let staging = ModelDownloader.cacheSnapshotDirectory(for: id).deletingLastPathComponent()
                .appendingPathComponent(".selection-staging", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let payload = Data("verified selected weights".utf8)
            let file = staging.appendingPathComponent("model.safetensors")
            try payload.write(to: file)
            let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            let aggregate = try #require(WeightHasher.hashFilesWithRelativeKey([(file: file, sortKey: "model.safetensors")]))
            let prefix = "v2/selection/\(UUID().uuidString)/new"
            let manifest = ModelManifest(schemaVersion: 1, modelID: id, version: "new", r2Prefix: prefix,
                aggregateSHA256: aggregate, totalSizeBytes: Int64(payload.count), fileCount: 1,
                files: [.init(path: "model.safetensors", sizeBytes: Int64(payload.count), sha256: digest, role: "weight")],
                createdAt: Date())
            let model = CatalogModel(id: id, s3Name: prefix, displayName: id, sizeGb: 0,
                version: manifest.version, r2Prefix: prefix, aggregateSHA256: aggregate)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SelectionManifestURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let manifestURL = try #require(URL(string: "https://selection.invalid/\(prefix)/manifest.json"))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            SelectionManifestURLProtocol.set(try encoder.encode(manifest), url: manifestURL)
            return Self(id: id, model: model, manifest: manifest, staging: staging,
                revision: try ModelDownloader.revisionSnapshotDirectory(manifest: manifest),
                downloader: ModelDownloader(r2CDNURL: "https://selection.invalid", urlSession: session),
                session: session, manifestURL: manifestURL)
        }

        func publish(activate: Bool = true) throws {
            try ModelDownloader.publishRevision(stagingDir: staging, directory: revision, manifest: manifest)
            if activate { try ModelDownloader.activateRevision(modelID: id, directory: revision) }
        }

        func clean() {
            session.invalidateAndCancel()
            SelectionManifestURLProtocol.set(nil, url: manifestURL)
            try? FileManager.default.removeItem(at: modelDirectory)
        }
    }

    @Test func currentImmutableRevisionHasZeroRemainingDownloadWithoutActivation() async throws {
        let f = try Fixture.make()
        defer { f.clean() }
        try f.publish(activate: false)
        let plan = try await f.downloader.selectedDownloadPlan(models: [f.model])
        #expect(plan.remainingBytes == 0)
        #expect(ModelScanner.resolveLocalPath(modelID: f.id) == nil)
    }

    @Test func planningUsesCanonicalDanglingCacheLinkRepair() async throws {
        let f = try Fixture.make()
        defer { f.clean() }
        try FileManager.default.removeItem(at: f.modelDirectory)
        try FileManager.default.createSymbolicLink(atPath: f.modelDirectory.path,
            withDestinationPath: "offline/selected-model")
        let plan = try await f.downloader.selectedDownloadPlan(models: [f.model])
        #expect(plan.remainingBytes == f.manifest.totalSizeBytes)
        #expect(FileManager.default.fileExists(atPath: f.modelDirectory.appendingPathComponent("snapshots").path))
        let parent = f.modelDirectory.deletingLastPathComponent()
        let backups = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".\(f.modelDirectory.lastPathComponent).unavailable-link-") }
        defer { for backup in backups { try? FileManager.default.removeItem(at: backup) } }
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: backup.path) == "offline/selected-model")
    }

    @Test func verificationRepairsManagedReceiptOnlyAfterCheckingBytes() async throws {
        let f = try Fixture.make()
        defer { f.clean() }
        try f.publish()
        try FileManager.default.removeItem(at: f.revision.appendingPathComponent(".darkbloom-manifest.json"))
        try await f.downloader.verifySelectedModel(f.model)
        #expect(ModelDownloader.selectedRevisionMatches(modelID: f.id,
            version: f.manifest.version, aggregateSHA256: f.manifest.aggregateSHA256))
    }

    @Test func matchingLegacySnapshotsRemainValidWithoutReceiptMigration() async throws {
        let f = try Fixture.make()
        defer { f.clean() }
        let legacy = ModelDownloader.cacheSnapshotDirectory(for: f.id)
        try FileManager.default.moveItem(at: f.staging, to: legacy)
        try await f.downloader.verifySelectedModel(f.model)
        #expect(ModelDownloader.revisionReceipt(at: legacy) == nil)
        #expect(!FileManager.default.fileExists(atPath: f.modelDirectory.appendingPathComponent("refs/main").path))
    }

    @Test(arguments: ["chat_template.jinja", "adapters/extra.safetensors"])
    func unmanifestedIntegrityFilesCannotPassSelectionVerification(extra: String) async throws {
        let f = try Fixture.make()
        defer { f.clean() }
        try f.publish()
        let extraFile = f.revision.appendingPathComponent(extra)
        try FileManager.default.createDirectory(at: extraFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unapproved runtime bytes".utf8).write(to: extraFile)
        await #expect(throws: ModelCatalogError.self) { try await f.downloader.verifySelectedModel(f.model) }
        #expect(ModelScanner.resolveLocalPath(modelID: f.id) == f.revision.resolvingSymlinksInPath())
    }

    @Test func oldManagedRevisionWithIdenticalBytesDoesNotVerifyAsLatest() async throws {
        let f = try Fixture.make()
        defer { f.clean() }
        let old = ModelManifest(schemaVersion: f.manifest.schemaVersion, modelID: f.id,
            version: "old", r2Prefix: "v2/selection/old", aggregateSHA256: f.manifest.aggregateSHA256,
            totalSizeBytes: f.manifest.totalSizeBytes, fileCount: f.manifest.fileCount,
            files: f.manifest.files, createdAt: f.manifest.createdAt)
        let oldDirectory = try ModelDownloader.revisionSnapshotDirectory(manifest: old)
        try ModelDownloader.publishRevision(stagingDir: f.staging, directory: oldDirectory, manifest: old)
        try ModelDownloader.activateRevision(modelID: f.id, directory: oldDirectory)
        #expect(ModelDownloader.verifiedRevisionExists(at: oldDirectory, manifest: f.manifest))
        await #expect(throws: ModelCatalogError.self) { try await f.downloader.verifySelectedModel(f.model) }
        #expect(ModelDownloader.revisionReceipt(at: oldDirectory)?.version == "old")
        #expect(ModelScanner.resolveLocalPath(modelID: f.id) == oldDirectory.resolvingSymlinksInPath())
    }

    @Test func setupPlanRetainsForegroundPartialDownloadCredit() async throws {
        let f = try Fixture.make()
        defer { f.clean() }
        let staging = f.revision.deletingLastPathComponent()
            .appendingPathComponent(ModelDownloader.localStagingDirName(r2Prefix: f.manifest.r2Prefix))
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("verified".utf8).write(to: staging.appendingPathComponent("model.safetensors.part"))
        let plan = try await f.downloader.selectedDownloadPlan(models: [f.model])
        #expect(plan.remainingBytes == f.manifest.totalSizeBytes - 8)
        #expect(ModelScanner.resolveLocalPath(modelID: f.id) == nil)
    }
}
