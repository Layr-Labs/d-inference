import Foundation
import Testing
@testable import ProviderCore

/// A two-file snapshot (`config.json`, `model.safetensors`) and a record file
/// in a private temporary directory.
private struct VerifiedWeightsFixture {
    let root: URL
    let snapshot: URL
    let records: URL
    let aggregate = String(repeating: "ab", count: 32)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("verified-weights-\(UUID().uuidString)", isDirectory: true)
        snapshot = root.appendingPathComponent("snapshot", isDirectory: true)
        records = root.appendingPathComponent("state/verified-weights.json")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        try Data(repeating: 7, count: 4096).write(to: weights)
    }

    var weights: URL { snapshot.appendingPathComponent("model.safetensors") }

    func identities() throws -> [VerifiedWeightHashStore.FileIdentity] {
        try #require(VerifiedWeightHashStore.fileIdentities(snapshotDir: snapshot))
    }

    func recordCurrent() throws {
        VerifiedWeightHashStore.record(
            modelID: "glm", aggregateSHA256: aggregate, identities: try identities(), at: records)
    }

    func recorded() -> String? {
        VerifiedWeightHashStore.verifiedHash(
            modelID: "glm", identities: VerifiedWeightHashStore.fileIdentities(snapshotDir: snapshot),
            at: records)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct VerifiedWeightHashStoreTests {
    @Test func recordIsReusedWhileEveryFileIdentityMatches() throws {
        let fixture = try VerifiedWeightsFixture()
        defer { fixture.remove() }
        #expect(fixture.recorded() == nil)
        try fixture.recordCurrent()
        #expect(fixture.recorded() == fixture.aggregate)
        #expect(VerifiedWeightHashStore.verifiedHash(
            modelID: "other", identities: try fixture.identities(), at: fixture.records) == nil)
        let mode = try FileManager.default.attributesOfItem(atPath: fixture.records.path)[.posixPermissions]
        #expect((mode as? NSNumber)?.intValue == 0o600)
    }

    @Test func rewrittenFileInvalidatesTheRecordEvenWithItsOldSizeAndTime() throws {
        let fixture = try VerifiedWeightsFixture()
        defer { fixture.remove() }
        try fixture.recordCurrent()
        let modified = try #require(
            try FileManager.default.attributesOfItem(atPath: fixture.weights.path)[.modificationDate] as? Date)
        try Data(repeating: 8, count: 4096).write(to: fixture.weights)
        // Restoring the modification time cannot restore the status-change
        // time (or the inode an atomic replacement gets).
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: fixture.weights.path)
        #expect(fixture.recorded() == nil)
    }

    @Test func appendedAndAddedFilesInvalidateTheRecord() throws {
        let fixture = try VerifiedWeightsFixture()
        defer { fixture.remove() }
        try fixture.recordCurrent()
        try Data("{}".utf8).write(to: fixture.snapshot.appendingPathComponent("tokenizer.json"))
        #expect(fixture.recorded() == nil)
        try fixture.recordCurrent()
        #expect(fixture.recorded() == fixture.aggregate)
        let handle = try FileHandle(forWritingTo: fixture.weights)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([1]))
        try handle.close()
        #expect(fixture.recorded() == nil)
    }

    @Test func unreadableOrForeignStateIsIgnoredAndReplaced() throws {
        let fixture = try VerifiedWeightsFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.records.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fixture.records)
        #expect(fixture.recorded() == nil)
        try Data(#"{"schema":2,"records":{}}"#.utf8).write(to: fixture.records)
        #expect(fixture.recorded() == nil)
        try fixture.recordCurrent()
        #expect(fixture.recorded() == fixture.aggregate)
    }

    @Test func onlyManagedGLMModelsAreVerifiedByTheirLoad() {
        #expect(ModelInfo(id: "g", modelType: "glm5_next", sizeBytes: 1, estimatedMemoryGb: 1)
            .weightsVerifiedByManagedLoad)
        #expect(!ModelInfo(id: "q", modelType: "qwen3", sizeBytes: 1, estimatedMemoryGb: 1)
            .weightsVerifiedByManagedLoad)
        #expect(!ModelInfo(id: "n", sizeBytes: 1, estimatedMemoryGb: 1).weightsVerifiedByManagedLoad)
    }
}
