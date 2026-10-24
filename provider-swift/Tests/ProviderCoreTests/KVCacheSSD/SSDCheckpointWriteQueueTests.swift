import Foundation
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Complete-checkpoint write queue", .serialized)
struct SSDCheckpointWriteQueueTests {
    @Test("GLM5-Next stores queue eight donations behind the writer; other layouts keep one")
    func queueDepthFollowsLayout() {
        #expect(SSDPrefixCachePolicy.completeCheckpointWriteQueueJobs(
            backendLayout: CBv2CompleteCheckpointManifest.glm5NextPagedLayout) == 8)
        for layout in [CBv2CompleteCheckpointManifest.layout, CBv2CompleteCheckpointManifest.pagedLayout,
                       CBv2CompleteCheckpointManifest.historicalAttentionLayout,
                       CBv2CompleteCheckpointManifest.diffusionBlockLayout] {
            #expect(SSDPrefixCachePolicy.completeCheckpointWriteQueueJobs(backendLayout: layout) == 1)
        }
    }

    @Test("donors finishing together queue behind a busy writer up to the store's depth")
    func donorsFinishingTogetherQueueBehindTheWriter() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 6_145)
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(donationRecorder: outcomes, writeQueueJobs: 3)
        defer { store.close() }
        let barrier = SSDCheckpointCoordinationTestSupport.Barrier()
        defer { barrier.release() }
        store.afterPublishBeforeIndexForTesting = { try? barrier.block() }
        store.registerDonationDemand(.init(repeatedPrefixTokens: 5_120), requestID: .init(8))
        func donate(_ position: Int) throws -> Task<[Int], Never> {
            let source = try fixture.source(position: position)
            return Task {
                await withCheckedContinuation { continuation in
                    store.donate(source, requestID: .init(8), tokens: fixture.tokens, cacheSalt: "tenant-a") {
                        continuation.resume(returning: $0)
                    }
                }
            }
        }
        let written = try donate(1_024)
        try await SSDCheckpointCoordinationTestSupport.waitUntil { barrier.isEntered }
        let queuedPositions = [2_048, 3_072, 4_096]
        let queued = try queuedPositions.map(donate)
        try await SSDCheckpointCoordinationTestSupport.waitUntil {
            store.lock.withLock { store.writing.count == 4 }
        }
        #expect(try await fixture.donate(store, receipt: 8, position: 5_120).isEmpty)
        #expect(outcomes.snapshot().first { $0.outcome == .writeQueueFull }?.count == 1)
        barrier.release()
        #expect(await written.value == [1_024])
        for (task, position) in zip(queued, queuedPositions) {
            #expect(await task.value == [position])
        }
        #expect(store.stats().filesWritten == 4)
        #expect(outcomes.snapshot().first { $0.outcome == .donated }?.count == 4)
        #expect(store.lock.withLock { store.writing.isEmpty })
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
    }
}
