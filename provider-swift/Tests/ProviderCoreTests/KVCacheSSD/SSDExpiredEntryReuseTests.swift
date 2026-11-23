import CryptoKit
import Foundation
import MLX
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

/// An entry past its TTL is never reused or advertised, even before a sweep
/// removes it: attention-block stages count only fresh blocks, and a complete
/// checkpoint's delta, re-donation and ready publication check every link.
@Suite("Expired SSD entries are not reused", .serialized)
struct SSDExpiredEntryReuseTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: Int64
        init(_ seconds: Int64) { self.seconds = seconds }
        var now: Int64 { lock.withLock { seconds } }
        func set(_ value: Int64) { lock.withLock { seconds = value } }
    }

    final class Publications: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PrefixCacheReadyResult] = []
        func append(_ value: PrefixCacheReadyResult) { lock.withLock { values.append(value) } }
        var snapshot: [PrefixCacheReadyResult] { lock.withLock { values } }
    }

    // MARK: - Attention blocks

    private static let blockSize = 8
    private static let layerKinds: [CBv2LayerKind] = [
        CBv2LayerKind(attention: .full, headDim: 8, kvHeads: 2, queryHeads: 4),
        CBv2LayerKind(attention: .slidingWindow(4), headDim: 8, kvHeads: 2, queryHeads: 4),
    ]

    private static func snapshots(tokenCount: Int) -> [(keys: MLXArray, values: MLXArray, offset: Int)?] {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        let shape = [1, 2, tokenCount, 8]
        let base = MLXArray(0 ..< shape.reduce(1, *)).reshaped(shape).asType(.float16)
        let values = (base * 1.5).asType(.float16)
        eval(base, values)
        return [(keys: base, values: values, offset: tokenCount), nil]
    }

    private static func attentionCache(
        dir: URL, clock: Clock, ttlSeconds: Int64, ttlMode: SSDPrefixCachePolicy.TTLMode
    ) -> SSDPrefixCache {
        SSDPrefixCache(
            config: .init(
                modelId: "test-model", promptContractID: "test-prompt-contract", weightHash: "test-weight-hash",
                blockSize: blockSize, adoptionBoundTokens: 0,
                layoutEpoch: SSDBlockStore.layoutEpoch(blockSize: blockSize, layerKinds: layerKinds),
                root: dir, ttlSeconds: ttlSeconds, ttlMode: ttlMode, minEffectiveTokens: blockSize,
                maxStageBytes: 1 << 30, maxStageMillis: 1_000_000, nowSeconds: { clock.now }),
            kekKey: SymmetricKey(size: .bits256), kvBudget: nil, diskBudget: SSDDiskBudget(),
            maxWriteBytesPerDay: 0, strictFsync: false, diskBudgetBytes: { 1 << 40 })
    }

    @Test("an attention block past its TTL is not staged before a sweep removes it", arguments: [
        SSDPrefixCachePolicy.TTLMode.sliding, .fixed,
    ])
    func expiredBlocksAreNotStaged(ttlMode: SSDPrefixCachePolicy.TTLMode) async throws {
        let dir = try SSDTestDirectory.parent()
            .appendingPathComponent("ssd-fresh-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock(10_000)
        // No background tasks: nothing sweeps the index during the test.
        let cache = Self.attentionCache(dir: dir, clock: clock, ttlSeconds: 10, ttlMode: ttlMode)
        defer { cache.close() }
        let tokens = Array(0 ..< 64)
        cache.donate(tokens: tokens, snapshots: Self.snapshots(tokenCount: 64), layerKinds: Self.layerKinds,
                     cacheSalt: nil)
        let deadline = ContinuousClock.now + .seconds(20)
        while cache.index.count < 8, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try #require(cache.index.count == 8)
        await cache.waitForWritesForTesting()

        // A hit 5 s after the write restarts only a sliding TTL.
        clock.set(10_005)
        #expect(await cache.stage(requestID: "hit", promptTokens: tokens + [1], cacheScope: "").staged)
        cache.completeStaging(requestID: "hit")

        // 11 s after the write: past a fixed TTL, inside the restarted sliding one.
        clock.set(10_011)
        #expect(cache.index.count == 8, "no sweep ran")
        let fresh = ttlMode == .sliding
        #expect((cache.estimatedPrefillTokensSaved(promptTokens: tokens + [2], cacheScope: "") > 0) == fresh)
        let late = await cache.stage(requestID: "late", promptTokens: tokens + [2], cacheScope: "")
        #expect(late.staged == fresh)
        if !fresh { #expect(late.disposition == .missAbsent) }
        cache.completeStaging(requestID: "late")

        // 10 s after the last hit, both modes are past the TTL.
        clock.set(10_021)
        let expired = await cache.stage(requestID: "expired", promptTokens: tokens + [3], cacheScope: "")
        #expect(expired.disposition == .missAbsent)
        #expect(cache.index.count == 8, "still no sweep: the stage alone refused the expired blocks")
    }

    // MARK: - Complete checkpoints

    private static func completeStore(
        _ f: SSDHybridCheckpointTestFixture, clock: Clock, ttlSeconds: Int64 = 100,
        ttlMode: SSDPrefixCachePolicy.TTLMode = .fixed
    ) throws -> SSDHybridCheckpointStore {
        let epoch = try SSDCacheEpochStore(root: f.modelRoot, binding: .init(
            modelId: "fixture-model", modelAggregateHash: f.identity.modelAggregateHash,
            promptContractId: f.identity.promptContractID, blockHashVersion: CBv2BlockHasher.version,
            blockSize: PrefixCachePolicy.blockSize, layoutEpoch: SSDHybridCheckpointEnvelope.layoutEpoch(
                identity: f.identity, backendLayout: f.backendLayout), keyFingerprint: "fixture-key"))
        let store = SSDHybridCheckpointStore(config: .init(
            modelId: "fixture-model", identity: f.identity, backendLayout: f.backendLayout,
            root: f.modelRoot, dedicatedRoot: f.root, epochStore: epoch,
            maxReadBytes: 16 << 20, maxStageMillis: 1000, minEffectiveTokens: 256,
            ttlSeconds: ttlSeconds, ttlMode: ttlMode, strictFsync: false, nowSeconds: { clock.now },
            diskBudgetBytes: { 1 << 30 }, maintainWholeRoot: {}, incrementalCheckpoints: true),
            kekKey: f.key, kvBudget: f.budget, diskBudget: SSDDiskBudget(), maxWriteBytesPerDay: 1 << 30)
        store.scanOnDisk()
        return store
    }

    private static func donate(_ f: SSDHybridCheckpointTestFixture, _ store: SSDHybridCheckpointStore,
                               id: UInt64, position: Int) async throws -> [Int] {
        let source = try SSDCheckpointDeltaTests.source(f, position)
        return await withCheckedContinuation { continuation in
            store.donate(source, requestID: .init(id), tokens: f.tokens, cacheSalt: "tenant-a") {
                continuation.resume(returning: $0)
            }
        }
    }

    /// Stages and consumes the 256-token checkpoint as request `id`, so its
    /// later donation may extend it.
    private static func restore(_ f: SSDHybridCheckpointTestFixture, _ store: SSDHybridCheckpointStore,
                                id: UInt64) async throws {
        let result = await store.stage(requestID: .init(id), request: f.request(),
                                       reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(result.disposition == .staged(matchedTokens: 256, expectedPrefillTokensSaved: 256,
                                              shortenedByCorruption: false))
        try #require(store.takeStaged(requestID: .init(id), tokens: f.tokens, cacheSalt: "tenant-a",
                                      maximumSequenceLength: f.tokens.count + 8)).close()
    }

    @Test("under a fixed TTL a delta needs a parent chain with half a TTL left; otherwise the turn writes a complete file",
          arguments: [(Int64(45), true), (Int64(60), false), (Int64(101), false)])
    func fixedTTLDeltaNeedsALiveParent(donateAt: Int64, writesDelta: Bool) async throws {
        let f = try SSDHybridCheckpointTestFixture(paged: true, tokenCount: 1025)
        defer { f.remove() }
        let clock = Clock(1_000)
        let store = try Self.completeStore(f, clock: clock)
        #expect(try await Self.donate(f, store, id: 1, position: 256) == [256])

        // The parent is staged while fresh, and the turn donates later.
        clock.set(1_000 + min(donateAt, 99) - 5)
        try await Self.restore(f, store, id: 2)
        clock.set(1_000 + donateAt)
        let published = Publications()
        store.registerReadyReceipt(requestID: .init(2), promptTokens: f.tokens, cacheScope: "tenant-a",
                                   callback: published.append)
        let positions = try await Self.donate(f, store, id: 2, position: 512)
        store.completeStaging(requestID: .init(2))
        #expect(positions == [512])
        #expect(store.stats().deltaFilesWritten == (writesDelta ? 1 : 0))
        store.publishReady(requestID: .init(2), positions: positions)
        #expect(published.snapshot.last?.readyTokens == 512)
        store.discardReadyReceipt(requestID: .init(2))

        // What was advertised restores now.
        clock.set(1_000 + donateAt + 1)
        let next = await store.stage(requestID: .init(3), request: f.request(),
                                     reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(next.stagedTokens == 512)
        await store.abandonStaging(requestID: .init(3))
        await store.closeAndWait()
        #expect(await f.budget.outstandingReservedBytes() == 0)
    }

    @Test("a checkpoint past its TTL is written again on a re-donation, not reported durable")
    func expiredCheckpointIsRewritten() async throws {
        let f = try SSDHybridCheckpointTestFixture(paged: true, tokenCount: 1025)
        defer { f.remove() }
        let clock = Clock(1_000)
        let store = try Self.completeStore(f, clock: clock)
        #expect(try await Self.donate(f, store, id: 1, position: 256) == [256])
        #expect(store.stats().filesWritten == 1)

        clock.set(1_101)
        let published = Publications()
        store.registerReadyReceipt(requestID: .init(2), promptTokens: f.tokens, cacheScope: "tenant-a",
                                   callback: published.append)
        #expect(try await Self.donate(f, store, id: 2, position: 256) == [256])
        #expect(store.stats().filesWritten == 2, "the expired file is replaced, so the anchor is fresh")
        store.publishReady(requestID: .init(2), positions: [256])
        #expect(published.snapshot.last?.readyTokens == 256)
        store.discardReadyReceipt(requestID: .init(2))

        clock.set(1_102)
        let next = await store.stage(requestID: .init(3), request: f.request(),
                                     reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(next.stagedTokens == 256)
        await store.abandonStaging(requestID: .init(3))
        await store.closeAndWait()
    }

    @Test("a ready publication skips a checkpoint whose TTL ran out since its write")
    func publicationChecksTheTTL() async throws {
        let f = try SSDHybridCheckpointTestFixture(paged: true, tokenCount: 1025)
        defer { f.remove() }
        let clock = Clock(1_000)
        let store = try Self.completeStore(f, clock: clock)
        let published = Publications()
        store.registerReadyReceipt(requestID: .init(1), promptTokens: f.tokens, cacheScope: "tenant-a",
                                   callback: published.append)
        let positions = try await Self.donate(f, store, id: 1, position: 256)
        #expect(positions == [256])
        clock.set(1_100)
        store.publishReady(requestID: .init(1), positions: positions)
        #expect(published.snapshot.isEmpty)
        store.discardReadyReceipt(requestID: .init(1))
        await store.closeAndWait()
    }
}
