import Crypto
import Foundation
import Testing
@testable import ProviderCore
import ProviderCoreFoundation

struct RevisionActivationFixture {
    let id: String
    let oldDirectory: URL
    let newDirectory: URL
    let oldHash: String
    let newHash: String
    let loop: ProviderLoop
    let staged: StagedModelRevision

    static func make() async throws -> Self {
        let id = "test-org/revision-activation-\(UUID().uuidString)"
        let snapshots = ModelDownloader.cacheModelDirectory(for: id).appendingPathComponent("snapshots")
        func write(_ name: String, _ bytes: String) throws -> (URL, String) {
            let directory = snapshots.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("{\"model_type\":\"gpt_oss\"}".utf8).write(to: directory.appendingPathComponent("config.json"))
            try Data(bytes.utf8).write(to: directory.appendingPathComponent("model.safetensors"))
            let hash = try #require(WeightHasher.computeHash(snapshotDir: directory, modelID: id))
            let files = try ["config.json", "model.safetensors"].map { path in
                let data = try Data(contentsOf: directory.appendingPathComponent(path))
                return ManifestFile(path: path, sizeBytes: Int64(data.count),
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), role: "other")
            }
            let manifest = ModelManifest(schemaVersion: 1, modelID: id,
                version: name.replacingOccurrences(of: ".revision-", with: ""), r2Prefix: name,
                aggregateSHA256: hash, totalSizeBytes: files.reduce(0) { $0 + $1.sizeBytes },
                fileCount: files.count, files: files, createdAt: Date())
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: directory.appendingPathComponent(".darkbloom-manifest.json"))
            return (directory, hash)
        }
        let (oldDirectory, oldHash) = try write(".revision-old", "old")
        let (newDirectory, newHash) = try write(".revision-new", "new")
        try ModelDownloader.activateRevision(modelID: id, directory: oldDirectory)
        let oldInfo = ModelInfo(id: id, modelType: "gpt_oss", sizeBytes: 3, estimatedMemoryGb: 0.1, weightHash: oldHash)
        let config = ProviderLoopConfig(
            coordinatorURL: "ws://127.0.0.1:0/ignored",
            hardware: HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124, cpuCores: .init(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: [oldInfo],
            config: ProviderConfig(provider: ProviderSettings(name: "revision-test", memoryReserveGB: 1),
                backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 2)),
            modelHashes: [id: oldHash])
        let loop = try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
        await loop.setDaemonStateFileForTesting(snapshots.appendingPathComponent(".test-state.json"))
        let entry = CoordinatorMessage.DesiredModelEntry(modelName: id, desiredBuild: id, revision: "new", aggregateSHA256: newHash)
        await loop.revisionTestSetDesired(entry)
        let lease = try await ModelArtifactWriteLease.acquire(modelID: id)
        let staged = StagedModelRevision(entry: entry, directory: newDirectory,
            info: ModelInfo(id: id, modelType: "gpt_oss", sizeBytes: 3, estimatedMemoryGb: 0.1, weightHash: newHash), lease: lease, totalSizeBytes: 3)
        return .init(id: id, oldDirectory: oldDirectory, newDirectory: newDirectory,
            oldHash: oldHash, newHash: newHash, loop: loop, staged: staged)
    }

    func clean() { staged.lease.release(); _ = try? ModelDownloader.remove(modelID: id) }
}

extension ProviderLoop {
    func revisionTestSetDesired(_ entry: CoordinatorMessage.DesiredModelEntry) {
        desiredPrefetchTargets = [entry.desiredBuild]
        updateDesiredModelRevisions([entry])
    }
    func revisionTestPublishing(_ id: String, publishing: Bool) { prefetchPublicationCounts[id] = publishing ? 1 : nil }
    func revisionTestBusy(_ id: String, busy: Bool) { requestToModel["accepted"] = busy ? id : nil }
    func revisionTestHash(_ id: String) -> String? { modelHashes[id] }
    func revisionTestDraining(_ id: String) -> Bool { state.refusingNewWork(forModel: id) }
}

@Suite("Model revision activation", .serialized)
struct ModelRevisionActivationTests {
    @Test("same ID with a different hash remains pending even when advertised")
    func detectsReplacement() async throws {
        let f = try await RevisionActivationFixture.make()
        defer { f.clean() }
        #expect(await f.loop.pendingModelRevisions().count == 1)
    }

    @Test("a different version with identical bytes remains pending until that revision is selected")
    func detectsSameHashVersionChange() async throws {
        let f = try await RevisionActivationFixture.make()
        defer { f.clean() }
        await f.loop.revisionTestSetDesired(.init(modelName: f.id, desiredBuild: f.id,
            revision: "renamed", aggregateSHA256: f.oldHash))
        #expect(await f.loop.pendingModelRevisions().count == 1)
        await f.loop.revisionTestSetDesired(.init(modelName: f.id, desiredBuild: f.id,
            revision: "old", aggregateSHA256: f.oldHash))
        #expect(await f.loop.pendingModelRevisions().isEmpty)
    }

    @Test("accepted requests drain before the active snapshot or hash changes")
    func drainsThenActivates() async throws {
        let f = try await RevisionActivationFixture.make()
        defer { f.clean() }
        await f.loop.revisionTestBusy(f.id, busy: true)
        try await f.loop.beginModelRevisionDrain(f.staged)
        #expect(await f.loop.revisionTestDraining(f.id))
        #expect(try await !f.loop.commitModelRevisionIfIdle(f.staged))
        #expect(ModelScanner.resolveLocalPath(modelID: f.id) == f.oldDirectory)
        #expect(await f.loop.revisionTestHash(f.id) == f.oldHash)
        await f.loop.revisionTestBusy(f.id, busy: false)
        #expect(try await f.loop.commitModelRevisionIfIdle(f.staged))
        await f.loop.finishModelRevisionDrain(f.staged)
        #expect(ModelScanner.resolveLocalPath(modelID: f.id) == f.newDirectory)
        #expect(await f.loop.revisionTestHash(f.id) == f.newHash)
        #expect(await f.loop.pendingModelRevisions().isEmpty)
        #expect(await !f.loop.revisionTestDraining(f.id))
    }

    @Test("a superseded prepared revision cannot activate")
    func rejectsSupersededRevision() async throws {
        let f = try await RevisionActivationFixture.make()
        defer { f.clean() }
        try await f.loop.beginModelRevisionDrain(f.staged)
        await f.loop.revisionTestSetDesired(.init(modelName: f.id, desiredBuild: f.id,
            revision: "newer", aggregateSHA256: String(repeating: "e", count: 64)))
        await #expect(throws: CancellationError.self) { try await f.loop.commitModelRevisionIfIdle(f.staged) }
        await f.loop.finishModelRevisionDrain(f.staged)
        #expect(ModelScanner.resolveLocalPath(modelID: f.id) == f.oldDirectory)
        #expect(await !f.loop.revisionTestDraining(f.id))
    }

    @Test("activation failure restores selection and hash before reopening admission")
    func restoresAfterFailure() async throws {
        let f = try await RevisionActivationFixture.make()
        defer { f.clean() }
        try await f.loop.beginModelRevisionDrain(f.staged)
        try FileManager.default.removeItem(at: f.newDirectory)
        await #expect(throws: (any Error).self) { try await f.loop.commitModelRevisionIfIdle(f.staged) }
        await f.loop.finishModelRevisionDrain(f.staged)
        #expect(ModelScanner.resolveLocalPath(modelID: f.id) == f.oldDirectory)
        #expect(await f.loop.revisionTestHash(f.id) == f.oldHash)
        #expect(await !f.loop.revisionTestDraining(f.id))
    }
}


extension ModelRevisionActivationTests {
    @Test("an earlier prefetch publication must finish before revision draining starts")
    func waitsForEarlierPublication() async throws {
        let f = try await RevisionActivationFixture.make()
        defer { f.clean() }
        await f.loop.revisionTestPublishing(f.id, publishing: true)
        await #expect(throws: CancellationError.self) { try await f.loop.beginModelRevisionDrain(f.staged) }
        #expect(await !f.loop.revisionTestDraining(f.id))
        await f.loop.revisionTestPublishing(f.id, publishing: false)
        try await f.loop.beginModelRevisionDrain(f.staged)
        await f.loop.finishModelRevisionDrain(f.staged)
    }

    @Test("rollback storage failure keeps admission closed")
    func failedRecoveryStaysFenced() async throws {
        let f = try await RevisionActivationFixture.make()
        defer { f.clean() }
        try await f.loop.beginModelRevisionDrain(f.staged)
        let ref = ModelDownloader.cacheModelDirectory(for: f.id).appendingPathComponent("refs/main")
        try FileManager.default.removeItem(at: ref)
        try FileManager.default.createDirectory(at: ref, withIntermediateDirectories: true)
        try Data("ref-blocker".utf8).write(to: ref.appendingPathComponent("cannot-replace"))
        await #expect(throws: (any Error).self) { try await f.loop.commitModelRevisionIfIdle(f.staged) }
        await f.loop.finishModelRevisionDrain(f.staged)
        #expect(await f.loop.revisionTestDraining(f.id))
        #expect(await f.loop.pendingModelRevisions().count == 1)
    }
}
