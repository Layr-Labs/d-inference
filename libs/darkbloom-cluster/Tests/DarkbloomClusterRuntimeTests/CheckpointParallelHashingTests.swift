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

    /// Finding R1: the decoding rank of a phase split verified (hashed) the
    /// whole artifact twice, once per stage it loads, one file at a time.
    /// Within one load's scope the second verification of the same artifact
    /// under the same pins reuses the first, after confirming the files are
    /// unchanged; outside a scope every verification still hashes; and the
    /// default hashes several files at once.
    @Test func oneLoadVerifiesAnArtifactOnceAndHashesSeveralFilesAtOnce() throws {
        let fixture = try IndexedShardFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        func verify() throws -> VerifiedCheckpoint {
            try VerifiedCheckpointReuse.checkpoint(directory: fixture.root, configurationData: fixture.config,
                expectedAggregateSHA256: nil, maximumPayloadBytes: nil, expectedManifestSHA256: nil,
                hashingConcurrency: VerifiedCheckpoint.derivedHashingConcurrency())
        }
        let serial = try fixture.checkpoint()
        var before = VerifiedCheckpointReuse.hashedVerifications
        let (first, second) = try VerifiedCheckpointReuse.scope { (try verify(), try verify()) }
        #expect(first === second && first.aggregate == serial.aggregate)
        #expect(VerifiedCheckpointReuse.hashedVerifications - before == 1)
        before = VerifiedCheckpointReuse.hashedVerifications
        let third = try verify(), fourth = try verify()
        #expect(third !== fourth && VerifiedCheckpointReuse.hashedVerifications - before == 2)
        // Other configuration bytes are another verification, never a reuse.
        try VerifiedCheckpointReuse.scope {
            let kept = try verify()
            #expect(throws: (any Error).self) {
                _ = try VerifiedCheckpointReuse.checkpoint(directory: fixture.root, configurationData: fixture.config + Data(" ".utf8),
                    expectedAggregateSHA256: nil, maximumPayloadBytes: nil, expectedManifestSHA256: nil, hashingConcurrency: 1)
            }
            // A file changed after the first verification: the reuse is refused.
            let shard = fixture.root.appendingPathComponent("model-00001-of-00001.safetensors")
            var times = [timeval(tv_sec: 1_000, tv_usec: 0), timeval(tv_sec: 1_000, tv_usec: 0)]
            #expect(utimes(shard.path, &times) == 0)
            #expect(throws: ProbeError.self) { _ = try verify() }
            _ = kept
        }
        #expect(VerifiedCheckpoint.derivedHashingConcurrency(activeProcessors: 32) == 8)
        #expect(VerifiedCheckpoint.derivedHashingConcurrency(activeProcessors: 12) == 3)
        #expect(VerifiedCheckpoint.derivedHashingConcurrency(activeProcessors: 2) == 1)
        #expect(VerifiedCheckpoint.derivedHashingConcurrency() > 1 || ProcessInfo.processInfo.activeProcessorCount < 8)
    }
}
