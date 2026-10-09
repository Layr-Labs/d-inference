import Foundation
import Testing
@testable import DarkbloomClusterRuntime

// Hashing several files of an artifact at once verifies exactly what the
// original one-file-at-a-time pass verifies. CPU fixture, no model.

@Suite("Checkpoint verification with several files hashed at once (CPU fixture)")
struct CheckpointParallelHashingTests {
    @Test func hashingSeveralFilesAtOnceVerifiesTheSameArtifact() throws {
        let fixture = try IndexedShardFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let serial = try fixture.checkpoint()
        for concurrency in [2, 3, 6, 16] {
            let parallel = try VerifiedCheckpoint(directory: fixture.root, configurationData: fixture.config,
                                                  hashingConcurrency: concurrency)
            #expect(parallel.aggregate == serial.aggregate && Set(parallel.files.keys) == Set(serial.files.keys))
            #expect(parallel.configurationSHA256 == serial.configurationSHA256)
        }
        for concurrency in [0, -1, 17] {
            #expect(throws: ProbeError.self) {
                _ = try VerifiedCheckpoint(directory: fixture.root, configurationData: fixture.config,
                                           hashingConcurrency: concurrency)
            }
        }
        // One altered byte in any one file is refused whichever thread hashed it.
        let shard = fixture.root.appendingPathComponent("model-00001-of-00001.safetensors")
        var bytes = try Data(contentsOf: shard)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: shard)
        for concurrency in [1, 4] {
            #expect(throws: ProbeError.self) {
                _ = try VerifiedCheckpoint(directory: fixture.root, configurationData: fixture.config,
                                           hashingConcurrency: concurrency)
            }
        }
    }
}
