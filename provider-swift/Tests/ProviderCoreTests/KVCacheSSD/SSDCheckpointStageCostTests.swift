import Foundation
import MLX
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Complete-checkpoint ready-receipt stage estimate", .serialized)
struct SSDCheckpointStageCostTests {
    /// The measured 8,192-token GLM checkpoint; 201 ms at the planning rate.
    private let glmCheckpointBytes = 300_547_000

    @Test("a GLM store starts from its measured fixed part; other layouts price bytes only")
    func priorFollowsLayout() {
        #expect(SSDCheckpointStageCost.priorOverheadMilliseconds(
            backendLayout: CBv2CompleteCheckpointManifest.glm5NextPagedLayout) == 935)
        for layout in [CBv2CompleteCheckpointManifest.layout, CBv2CompleteCheckpointManifest.pagedLayout,
                       CBv2CompleteCheckpointManifest.historicalAttentionLayout] {
            #expect(SSDCheckpointStageCost.priorOverheadMilliseconds(backendLayout: layout) == 0)
        }
        #expect(SSDPrefixCachePolicy.estimatedStageMillisDouble(bytes: glmCheckpointBytes) == 201)
        let glm = SSDCheckpointStageCost(priorOverheadMilliseconds: 935)
        #expect(glm.estimatedMilliseconds(bytes: glmCheckpointBytes) == 1_136)
        #expect(glm.estimatedMilliseconds(bytes: 0) == 0)
        #expect(SSDCheckpointStageCost(priorOverheadMilliseconds: 0)
            .estimatedMilliseconds(bytes: glmCheckpointBytes) == 201)
    }

    @Test("the first measured stage replaces the prior; later ones average in at a quarter")
    func measuredStagesMoveTheEstimate() {
        let cost = SSDCheckpointStageCost(priorOverheadMilliseconds: 935)
        cost.record(bytes: glmCheckpointBytes, milliseconds: 1_001)
        #expect(cost.estimatedMilliseconds(bytes: glmCheckpointBytes) == 1_001)
        // 187,126,608 bytes price at 125 ms: 400 ms beyond the price.
        cost.record(bytes: 187_126_608, milliseconds: 525)
        #expect(cost.estimatedMilliseconds(bytes: glmCheckpointBytes) == 901)
        // A stage faster than its byte price counts as no fixed part.
        cost.record(bytes: glmCheckpointBytes, milliseconds: 50)
        #expect(cost.estimatedMilliseconds(bytes: glmCheckpointBytes) == 726)
        cost.record(bytes: 0, milliseconds: 5_000)
        cost.record(bytes: glmCheckpointBytes, milliseconds: .nan)
        cost.record(bytes: glmCheckpointBytes, milliseconds: -1)
        #expect(cost.estimatedMilliseconds(bytes: glmCheckpointBytes) == 726)
        #expect(cost.estimatedMilliseconds(bytes: .max) == PrefixCacheReadyResult.maxStageMs)
    }

    @Test("ready receipts price the store's own first-attempt restores, not retried ones",
          arguments: [false, true])
    func readyReceiptLearnsFromStagedRestores(_ retried: Bool) async throws {
        try await SSDShorterRestoreFixture.withStore { fixture, donor in
            await donor.closeAndWait()
            let clock = SSDCheckpointTestClock()
            var config = donor.config
            config.stageNow = clock.now
            let store = SSDHybridCheckpointStore(config: config, kekKey: fixture.key, kvBudget: fixture.budget,
                diskBudget: SSDDiskBudget(), maxWriteBytesPerDay: 1 << 30)
            store.scanOnDisk()
            let bytes = try #require(try FileManager.default.attributesOfItem(
                atPath: fixture.file(store, position: 512).path)[.size] as? Int)
            let priced = SSDPrefixCachePolicy.estimatedStageMillisDouble(bytes: bytes)
            let receipts = Receipts()
            func readyStageMs(_ receipt: UInt64) throws -> Double {
                store.registerReadyReceipt(requestID: .init(receipt), promptTokens: fixture.tokens,
                                           cacheScope: "tenant-a", callback: receipts.append)
                store.publishReady(requestID: .init(receipt), positions: [512])
                return try #require(receipts.last?.stageMs)
            }
            #expect(try readyStageMs(960) == priced)
            let probe = SSDShorterRestoreProbe()
            let result = await store.stage(requestID: .init(950), request: fixture.request(),
                reserveReadScratch: { try probe.scratch(fixture) }) { manifest in
                    if retried && manifest.position == 512 {
                        throw CBv2KVError.capacityExhausted(needed: 2, available: 1)
                    }
                    clock.advance(.milliseconds(600))
                    return try probe.cpuPlan(manifest, fixture: fixture)
                }
            #expect(result.staged && result.stagedTokens == (retried ? 256 : 512) && result.stageMs == 600)
            // A retried stage also paid for its refused first attempt.
            #expect(try readyStageMs(961) == (retried ? priced : 600))
            await store.closeAndWait()
            #expect(await fixture.budget.outstandingReservedBytes() == 0)
            #expect(fixture.codec.admission.bytesReserved == 0)
        }
    }

    private final class Receipts: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PrefixCacheReadyResult] = []
        func append(_ value: PrefixCacheReadyResult) { lock.withLock { values.append(value) } }
        var last: PrefixCacheReadyResult? { lock.withLock { values.last } }
    }
}
