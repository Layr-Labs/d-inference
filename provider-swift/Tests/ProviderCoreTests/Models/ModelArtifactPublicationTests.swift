import Crypto
import Darwin
import Foundation
import Testing
@testable import ProviderCore
import ProviderCoreFoundation

@Suite("Model artifact publication")
struct ModelArtifactPublicationTests {
    private struct Fixture {
        let modelID = "test-org/artifact-publication-\(UUID().uuidString)"
        var modelDirectory: URL { ModelDownloader.cacheModelDirectory(for: modelID) }
        var snapshots: URL { modelDirectory.appendingPathComponent("snapshots", isDirectory: true) }

        func stage(version: String = "new") throws -> (URL, URL, ModelManifest) {
            let staging = snapshots.appendingPathComponent(".staging-\(version)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let bytes = Data("verified \(version) weights".utf8)
            let path = "model.safetensors"
            try bytes.write(to: staging.appendingPathComponent(path))
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let aggregate = try #require(WeightHasher.hashFilesWithRelativeKey([
                (file: staging.appendingPathComponent(path), sortKey: path)
            ]))
            let manifest = ModelManifest(schemaVersion: 1, modelID: modelID,
                version: version, r2Prefix: "v2/artifact-publication/\(version)",
                aggregateSHA256: aggregate, totalSizeBytes: Int64(bytes.count), fileCount: 1,
                files: [ManifestFile(path: path, sizeBytes: Int64(bytes.count), sha256: hash, role: "weight")],
                createdAt: Date())
            return (staging, try ModelDownloader.revisionSnapshotDirectory(manifest: manifest), manifest)
        }

        func clean() { try? FileManager.default.removeItem(at: modelDirectory) }
    }

    @Test("an initial activation is discoverable after publication without the final ref write")
    func initialPublicationSurvivesCrashBeforeActivation() throws {
        let f = Fixture()
        defer { f.clean() }
        let (staging, directory, manifest) = try f.stage()
        #expect(ModelScanner.resolveLocalPath(modelID: f.modelID) == nil)
        try ModelDownloader.publishRevision(
            stagingDir: staging, directory: directory, manifest: manifest, activationRequested: true)
        // Simulate process death at the rename boundary: do not call
        // activateRevision. A fresh scan must find the complete bytes.
        #expect(ModelScanner.resolveLocalPath(modelID: f.modelID) == directory.resolvingSymlinksInPath())
        #expect(ModelDownloader.selectedRevisionMatches(modelID: f.modelID,
            version: manifest.version, aggregateSHA256: manifest.aggregateSHA256))
        #expect(ModelDownloader.verifiedRevisionExists(at: directory, manifest: manifest))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test("staged-only publication stays hidden without an existing active model")
    func inactivePublicationDoesNotRecordActivationIntent() throws {
        let f = Fixture()
        defer { f.clean() }
        let (staging, directory, manifest) = try f.stage()
        try ModelDownloader.publishRevision(
            stagingDir: staging, directory: directory, manifest: manifest, activationRequested: false)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(ModelScanner.resolveLocalPath(modelID: f.modelID) == nil)
        #expect(!FileManager.default.fileExists(atPath: f.modelDirectory.appendingPathComponent("refs/main").path))
    }

    @Test("publication preserves an older managed or legacy selection until activation", arguments: [false, true])
    func updatePublicationKeepsExistingSelection(managed: Bool) throws {
        let f = Fixture()
        defer { f.clean() }
        let oldDirectory = f.snapshots.appendingPathComponent(managed ? ".revision-old" : "local", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        if managed { try ModelDownloader.activateRevision(modelID: f.modelID, directory: oldDirectory) }
        let (staging, directory, manifest) = try f.stage()
        try ModelDownloader.publishRevision(
            stagingDir: staging, directory: directory, manifest: manifest, activationRequested: true)
        #expect(ModelScanner.resolveLocalPath(modelID: f.modelID) == oldDirectory.resolvingSymlinksInPath())
        try ModelDownloader.activateRevision(modelID: f.modelID, directory: directory)
        #expect(ModelScanner.resolveLocalPath(modelID: f.modelID) == directory.resolvingSymlinksInPath())
    }

    @Test("a retry replaces an unfinished initial activation intent before publication")
    func retryAfterCrashBeforePublication() throws {
        let f = Fixture()
        defer { f.clean() }
        let refs = f.modelDirectory.appendingPathComponent("refs", isDirectory: true)
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        try ".revision-never-published".write(to: refs.appendingPathComponent("main"), atomically: true, encoding: .utf8)
        let (staging, directory, manifest) = try f.stage()
        #expect(ModelScanner.resolveLocalPath(modelID: f.modelID) == nil)
        try ModelDownloader.publishRevision(
            stagingDir: staging, directory: directory, manifest: manifest, activationRequested: true)
        #expect(ModelScanner.resolveLocalPath(modelID: f.modelID) == directory.resolvingSymlinksInPath())
    }

    @Test("a linked model cache supports initial activation and rollback without allowing external snapshots")
    func linkedCacheActivationAndRollback() throws {
        let f = Fixture()
        let fm = FileManager.default
        let external = fm.temporaryDirectory.appendingPathComponent("linked-revisions-\(UUID().uuidString)")
        defer { f.clean(); try? fm.removeItem(at: external) }
        let modelTarget = external.appendingPathComponent("model", isDirectory: true)
        try fm.createDirectory(at: modelTarget, withIntermediateDirectories: true)
        try fm.createDirectory(at: f.modelDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: f.modelDirectory.path, withDestinationPath: modelTarget.path)
        let (oldStaging, oldDirectory, oldManifest) = try f.stage(version: "old")
        // The target child does not exist yet when initial activation intent
        // validates its parent; resolve the existing parent through the link.
        #expect(!fm.fileExists(atPath: oldDirectory.path))
        try ModelDownloader.publishRevision(stagingDir: oldStaging, directory: oldDirectory,
            manifest: oldManifest, activationRequested: true)
        let previous = try #require(ModelScanner.resolveLocalPath(modelID: f.modelID))
        // Foundation may preserve /var while POSIX resolves it to /private/var.
        let canonicalPath = try #require(realpath(oldDirectory.path, nil))
        defer { free(canonicalPath) }
        #expect(previous == URL(fileURLWithPath: String(cString: canonicalPath), isDirectory: true))
        #expect(previous != oldDirectory)
        #expect(ModelDownloader.selectedRevisionMatches(modelID: f.modelID,
            version: oldManifest.version, aggregateSHA256: oldManifest.aggregateSHA256))
        let (nextStaging, nextDirectory, nextManifest) = try f.stage()
        try ModelDownloader.publishRevision(stagingDir: nextStaging, directory: nextDirectory, manifest: nextManifest)
        try ModelDownloader.activateRevision(modelID: f.modelID, directory: nextDirectory)
        // Rollback uses the resolved path returned by the scanner.
        try ModelDownloader.activateRevision(modelID: f.modelID, directory: previous)
        #expect(ModelScanner.resolveLocalPath(modelID: f.modelID) == previous)
        #expect(try String(contentsOf: f.modelDirectory.appendingPathComponent("refs/main"), encoding: .utf8)
            == previous.lastPathComponent)
        let outside = external.appendingPathComponent("unmanaged", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try ModelDownloader.activateRevision(modelID: f.modelID, directory: outside) }
        #expect(ModelScanner.resolveLocalPath(modelID: f.modelID) == previous)
    }

    @Test("shared manifest finalization honors activation and publishes immutable revisions", arguments: [false, true])
    func sharedFinalization(activate: Bool) throws {
        let f = Fixture()
        defer { f.clean() }
        let (staging, directory, manifest) = try f.stage()
        let model = CatalogModel(id: f.modelID, s3Name: "unused", displayName: f.modelID, sizeGb: 0,
            version: manifest.version, r2Prefix: manifest.r2Prefix, aggregateSHA256: manifest.aggregateSHA256)
        let downloader = ModelDownloader()
        try downloader.finalizeStagedManifest(model: model, manifest: manifest,
            jobs: downloader.manifestJobs(manifest, stagingDir: staging), stagingDir: staging,
            cacheDir: directory, activate: activate)
        #expect(ModelDownloader.verifiedRevisionExists(at: directory, manifest: manifest))
        #expect(ModelScanner.resolveLocalPath(modelID: f.modelID) == (activate ? directory.resolvingSymlinksInPath() : nil))
        #expect(!FileManager.default.fileExists(atPath: ModelDownloader.cacheSnapshotDirectory(for: f.modelID).path))
    }
}
