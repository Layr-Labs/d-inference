import Foundation
import MLX
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Shorter restore shares the original monotonic deadline", .serialized)
struct SSDShorterRestoreClockTests {
    @Test("retirement time and the second plan cannot obtain a fresh deadline", arguments: ["retirement", "second-plan", "first-success"])
    func deadlineDoesNotRestart(_ point: String) async throws {
        try await SSDShorterRestoreFixture.withStore { fixture, donor in
            await donor.closeAndWait()
            let clock = SSDCheckpointTestClock()
            var config = donor.config
            config.stageNow = clock.now
            let store = SSDHybridCheckpointStore(config: config, kekKey: fixture.key, kvBudget: fixture.budget,
                diskBudget: SSDDiskBudget(), maxWriteBytesPerDay: 1 << 30)
            store.scanOnDisk()
            let probe = SSDShorterRestoreProbe()
            let result = await store.stage(requestID: .init(940), request: fixture.request(), reserveReadScratch: {
                try probe.scratch(fixture, onRelease: { count in
                    if point == "retirement" && count == 1 { clock.advance(.milliseconds(1000)) }
                })
            }) { manifest in
                probe.record(manifest.position)
                if point == "first-success" {
                    clock.advance(.milliseconds(1001))
                } else if manifest.position == 512 {
                    throw CBv2KVError.capacityExhausted(needed: 2, available: 1)
                } else {
                    clock.advance(.milliseconds(1000))
                }
                return try probe.cpuPlan(manifest, fixture: fixture)
            }
            #expect(probe.positions == (point == "second-plan" ? [512, 256] : [512]))
            #expect(result.stageMs == (point == "first-success" ? 1001 : 1000))
            #expect(store.stats().stageMilliseconds == result.stageMs)
            #expect(store.stats().filesRead == (point == "retirement" ? 1 : 2))
            #expect(result.disposition == (point == "first-success"
                ? .staged(matchedTokens: 512, expectedPrefillTokensSaved: 512, shortenedByCorruption: false)
                : .skippedCapacity))
            #expect(probe.scratchCounts.0 == (point == "second-plan" ? 2 : 1))
            #expect(store.stats().entries == 2 && store.stats().corruptDropped == 0)
            await store.closeAndWait()
            #expect(await fixture.budget.outstandingReservedBytes() == 0)
            #expect(fixture.codec.admission.bytesReserved == 0)
        }
    }

    @Test func shorterFileLeaseWaitConsumesRemainingTime() async throws {
        try await SSDShorterRestoreFixture.withStore { fixture, donor in
            await donor.closeAndWait()
            let clock = SSDCheckpointTestClock()
            var config = donor.config
            config.stageNow = clock.now
            let store = SSDHybridCheckpointStore(config: config, kekKey: fixture.key, kvBudget: fixture.budget,
                diskBudget: SSDDiskBudget(), maxWriteBytesPerDay: 1 << 30)
            store.scanOnDisk()
            let file = fixture.file(store, position: 256)
            let held = store.fileCoordinator.makeAccess(to: file)
            try await held.acquire()
            let probe = SSDShorterRestoreProbe()
            let task = Task {
                await store.stage(requestID: .init(941), request: fixture.request(),
                    reserveReadScratch: { try probe.scratch(fixture) }) { manifest in
                        probe.record(manifest.position)
                        if manifest.position == 512 { throw CBv2KVError.capacityExhausted(needed: 2, available: 1) }
                        Issue.record("expired shorter-file wait reached a manifest plan")
                        return try probe.cpuPlan(manifest, fixture: fixture)
                    }
            }
            let queued = await SSDShorterRestoreGate.waitUntil { store.fileCoordinator.pendingCount(for: file) == 1 }
            #expect(queued)
            clock.advance(.milliseconds(1000))
            held.release()
            let result = await task.value
            #expect(result.disposition == .skippedCapacity && result.stageMs == 1000)
            #expect(probe.positions == [512] && store.stats().filesRead == 1)
            #expect(probe.scratchCounts.0 == 2 && probe.scratchCounts.1 == 2)
            #expect(store.stats().entries == 2 && store.stats().corruptDropped == 0)
            await store.closeAndWait()
            #expect(await fixture.budget.outstandingReservedBytes() == 0)
            #expect(fixture.codec.admission.bytesReserved == 0)
        }
    }
}
