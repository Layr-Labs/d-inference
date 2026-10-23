import Foundation
import ProviderCore
import Testing
@testable import darkbloom

/// Counts full weight reads behind startup registration hashes.
private final class HashReads: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.withLock { count } }
    func hash(_ directory: URL, _ modelID: String) -> String? {
        lock.withLock { count += 1 }
        return WeightHasher.computeHash(snapshotDir: directory, modelID: modelID)
    }
}

@Suite struct RegistrationWeightHashTests {
    private func snapshot() throws -> (root: URL, snapshot: URL, records: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("registration-hash-\(UUID().uuidString)", isDirectory: true)
        let snapshot = root.appendingPathComponent("snapshot", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        try Data(repeating: 5, count: 8192).write(to: snapshot.appendingPathComponent("model.safetensors"))
        return (root, snapshot, root.appendingPathComponent("verified-weights.json"))
    }

    @Test func managedGLMRestartRegistersTheRecordedHashWithoutReadingWeights() throws {
        let fixture = try snapshot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let glm = ModelInfo(id: "glm-5.3-flash", modelType: "glm5_next", sizeBytes: 1, estimatedMemoryGb: 1)
        let reads = HashReads()
        let expected = try #require(WeightHasher.computeHash(snapshotDir: fixture.snapshot))

        let first = registrationWeightHash(
            for: glm, snapshotDir: fixture.snapshot, verifiedWeightHashesFile: fixture.records,
            computeHash: reads.hash)
        #expect(first == expected && reads.reads == 1)
        let restart = registrationWeightHash(
            for: glm, snapshotDir: fixture.snapshot, verifiedWeightHashesFile: fixture.records,
            computeHash: reads.hash)
        #expect(restart == expected && reads.reads == 1)

        // Any write to a hashed file forces a full read and a new record.
        try Data(repeating: 6, count: 8192).write(
            to: fixture.snapshot.appendingPathComponent("model.safetensors"))
        let changed = registrationWeightHash(
            for: glm, snapshotDir: fixture.snapshot, verifiedWeightHashesFile: fixture.records,
            computeHash: reads.hash)
        #expect(reads.reads == 2)
        #expect(changed == WeightHasher.computeHash(snapshotDir: fixture.snapshot) && changed != expected)
    }

    @Test func modelsWithoutManagedVerificationAndRecordlessStartsAlwaysHash() throws {
        let fixture = try snapshot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reads = HashReads()
        let ordinary = ModelInfo(id: "qwen", modelType: "qwen3", sizeBytes: 1, estimatedMemoryGb: 1)
        for _ in 0..<2 {
            _ = registrationWeightHash(
                for: ordinary, snapshotDir: fixture.snapshot, verifiedWeightHashesFile: fixture.records,
                computeHash: reads.hash)
        }
        #expect(reads.reads == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.records.path))

        let glm = ModelInfo(id: "glm-5.3-flash", modelType: "glm5_next", sizeBytes: 1, estimatedMemoryGb: 1)
        for _ in 0..<2 {
            _ = registrationWeightHash(
                for: glm, snapshotDir: fixture.snapshot, verifiedWeightHashesFile: nil,
                computeHash: reads.hash)
        }
        #expect(reads.reads == 4)
    }
}
