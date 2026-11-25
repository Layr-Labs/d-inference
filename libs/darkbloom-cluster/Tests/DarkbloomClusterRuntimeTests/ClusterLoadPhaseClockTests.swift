import Foundation
import Testing
@testable import DarkbloomClusterRuntime

// The load-phase record (`ClusterLoadPhaseClock`): a checkpoint verification
// and a tensor read add their passes, a pass that throws still counts, and
// recording changes nothing a load returns. CPU fixture, no model. Other
// suites load in this process at the same time, so every check is on what
// this test added at least.

@Suite("Load phase clock (CPU fixture)")
struct ClusterLoadPhaseClockTests {
    private func total(_ phase: ClusterLoadPhaseClock.Phase) -> ClusterLoadPhaseClock.Total {
        ClusterLoadPhaseClock.totals[phase] ?? .init()
    }

    @Test func verificationAndTensorReadsAddTheirPasses() throws {
        let fixture = try IndexedShardFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let verified = total(.checkpointVerify)
        let checkpoint = try fixture.checkpoint()
        #expect(total(.checkpointVerify).count >= verified.count + 1)
        let descriptors = try tensorDescriptors(checkpoint: checkpoint, scope: .init(acceptsUInt8: true, indexedShardsOnly: true))
        let scales = try #require(descriptors["block.scales"])
        let read = total(.weightRead), copied = total(.weightCopy)
        let value = try scales.read(.all)
        // The bytes are the same as without the record.
        #expect(value.copiedBytes == 8 && value.array.asArray(UInt8.self) == fixture.scales)
        #expect(total(.weightRead).count >= read.count + 1 && total(.weightCopy).count >= copied.count + 1)
        // A verification that fails is timed too.
        let failed = total(.checkpointVerify)
        #expect(throws: ProbeError.self) {
            _ = try VerifiedCheckpoint(directory: fixture.root, configurationData: fixture.config + Data(" ".utf8))
        }
        #expect(total(.checkpointVerify).count >= failed.count + 1)
    }

    @Test func aTimedPassAddsItsDurationAndKeepsItsResultOrError() throws {
        let before = total(.linkProbe)
        let value = ClusterLoadPhaseClock.time(.linkProbe) { () -> Int in usleep(2_000); return 41 + 1 }
        #expect(value == 42)
        let after = total(.linkProbe)
        #expect(after.count >= before.count + 1 && after.nanoseconds >= before.nanoseconds + 2_000_000)
        #expect(throws: ProbeError.self) {
            try ClusterLoadPhaseClock.time(.linkProbe) { throw ProbeError("refused") }
        }
        #expect(total(.linkProbe).count >= after.count + 1)
        ClusterLoadPhaseClock.add(.linkProbe, nanoseconds: 3_000_000)
        #expect(total(.linkProbe).milliseconds >= after.milliseconds + 3)
    }
}
