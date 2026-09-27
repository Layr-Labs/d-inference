import Foundation
import MLX
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

/// Per-file removals (budget eviction, TTL expiry, corrupt drops) keep the
/// complete-checkpoint store's cache epoch, so the coordinator's evidence for
/// every surviving checkpoint stays valid and only the removed anchor misses.
/// The epoch still rotates for a whole-root rebuild (binding drift).
@Suite("Complete checkpoint epoch continuity", .serialized)
struct SSDEpochContinuityTests {
    private func tag(_ f: SSDHybridCheckpointTestFixture, _ store: SSDHybridCheckpointStore, position: Int) throws -> Data {
        try #require(SSDPrefixCache.hexDecode(
            f.file(store, position: position).deletingPathExtension().lastPathComponent))
    }

    private func persistedNextSequence(_ f: SSDHybridCheckpointTestFixture) throws -> UInt64 {
        let data = try Data(contentsOf: f.modelRoot.appendingPathComponent("cache-epoch.json"))
        let record = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require((record["nextSequence"] as? NSNumber)?.uint64Value)
    }

    @Test("evicting one checkpoint keeps the epoch; its anchor misses while another still hits")
    func evictionKeepsEpochAndOtherAnchors() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let budget = SSDDiskBudget()
        let store = try f.makeStore(diskBudget: budget)
        defer { store.close() }
        #expect(try await f.donate(store, position: 256) == [256])
        #expect(try await f.donate(store, receipt: 11, position: 512) == [512])
        let epoch = try #require(store.config.epochStore?.current)
        let capability = try #require(store.prefixCacheV2Capability())
        #expect(capability.cacheEpoch == epoch)
        #expect(store.takeNextPrefixCacheV2Sequence(expectedEpoch: epoch) == 1)

        // Make the 512-token checkpoint the LRU victim while both stay fresh.
        let now = Int64(Date().timeIntervalSince1970)
        let tag512 = try tag(f, store, position: 512)
        let tag256 = try tag(f, store, position: 256)
        store.index.touch(tags16: [tag512], now: now - 20)
        store.index.touch(tags16: [tag256], now: now - 10)
        #expect(store.evictOldestEntry() > 0)
        #expect(store.stats().evictions == 1)
        #expect(!store.index.contains(tag16: tag512))
        #expect(store.index.contains(tag16: tag256))
        #expect(!FileManager.default.fileExists(atPath: f.file(store, position: 512).path))

        #expect(store.config.epochStore?.current == epoch)
        #expect(store.prefixCacheV2Capability() == capability)
        #expect(store.takeNextPrefixCacheV2Sequence(expectedEpoch: epoch) == 2)
        // The longer anchor is gone, so the lookup lands on the shorter one.
        let staged = await store.stage(requestID: .init(701), request: f.request(),
                                       reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(staged.staged)
        #expect(staged.stagedTokens == 256)
        await store.abandonStaging(requestID: .init(701))

        // Evicting the last checkpoint turns the lookup into a plain miss,
        // still without a new epoch.
        #expect(store.evictOldestEntry() > 0)
        #expect(store.index.count == 0)
        let missed = await store.stage(requestID: .init(702), request: f.request(),
                                       reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(missed.disposition == .missAbsent)
        #expect(store.config.epochStore?.current == epoch)
        #expect(store.prefixCacheV2Capability() == capability)
        await store.closeAndWait()
    }

    @Test("a whole-root TTL sweep through the active store keeps the epoch and the capability")
    func ttlSweepKeepsEpoch() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        // The maintainer finds active stores through the shared budget.
        let store = try f.makeStore(diskBudget: .shared)
        defer { store.close() }
        #expect(try await f.donate(store, position: 256) == [256])
        #expect(try await f.donate(store, receipt: 11, position: 512) == [512])
        let epoch = try #require(store.config.epochStore?.current)
        let capability = try #require(store.prefixCacheV2Capability())
        #expect(store.takeNextPrefixCacheV2Sequence(expectedEpoch: epoch) == 1)

        let result = SSDWholeRootMaintainer().maintain(
            root: f.root, ttlSeconds: 1,
            nowSeconds: Int64(Date().timeIntervalSince1970) + 7_200, budgetBytes: Int.max)
        #expect(result.ttlExpired == 2)
        // Reconciled inside the removal barrier: no separate pass needed.
        #expect(store.index.count == 0)
        #expect(store.config.epochStore?.current == epoch)
        #expect(store.prefixCacheV2Capability() == capability)
        #expect(store.takeNextPrefixCacheV2Sequence(expectedEpoch: epoch) == 2)
        let missed = await store.stage(requestID: .init(711), request: f.request(),
                                       reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(missed.disposition == .missAbsent)
        await store.closeAndWait()
    }

    @Test("a corrupt checkpoint found by a read is dropped without rotating the epoch")
    func corruptReadKeepsEpoch() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let store = try f.makeStore()
        defer { store.close() }
        #expect(try await f.donate(store) == [256])
        let epoch = try #require(store.config.epochStore?.current)
        let capability = try #require(store.prefixCacheV2Capability())
        let file = f.file(store)
        try Data([0, 1, 2]).write(to: file)

        let result = await store.stage(requestID: .init(721), request: f.request(),
                                       reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(result.disposition == .missCorrupt)
        #expect(store.stats().corruptDropped == 1)
        #expect(store.index.count == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(store.config.epochStore?.current == epoch)
        #expect(store.prefixCacheV2Capability() == capability)
        await store.closeAndWait()
    }

    @Test("sequence numbers continue across eviction and a process restart on the same epoch")
    func sequenceContinuityAcrossRestart() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let first = try f.makeStore()
        let epoch = try #require(first.config.epochStore?.current)
        #expect(first.takeNextPrefixCacheV2Sequence(expectedEpoch: epoch) == 1)
        #expect(first.takeNextPrefixCacheV2Sequence(expectedEpoch: epoch) == 2)
        #expect(try await f.donate(first) == [256])
        #expect(first.evictOldestEntry() > 0)
        #expect(first.takeNextPrefixCacheV2Sequence(expectedEpoch: epoch) == 3)
        #expect(try persistedNextSequence(f) == 4)
        await first.closeAndWait()

        // A restart reopens the same record: same epoch, counter untouched.
        let restarted = try f.makeStore()
        defer { restarted.close() }
        #expect(restarted.config.epochStore?.current == epoch)
        #expect(restarted.prefixCacheV2Capability()?.cacheEpoch == epoch)
        #expect(restarted.takeNextPrefixCacheV2Sequence(expectedEpoch: epoch) == 4)
        #expect(try persistedNextSequence(f) == 5)
        await restarted.closeAndWait()
    }

    @Test("a crash between unlink and index update reconciles from disk on restart without a new epoch")
    func crashMidRemovalReconcilesOnRestart() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let first = try f.makeStore()
        #expect(try await f.donate(first, position: 256) == [256])
        #expect(try await f.donate(first, receipt: 11, position: 512) == [512])
        let epoch = try #require(first.config.epochStore?.current)
        #expect(first.takeNextPrefixCacheV2Sequence(expectedEpoch: epoch) == 1)
        // Simulate the crash: the file is gone, the RAM index never learned.
        try FileManager.default.removeItem(at: f.file(first, position: 512))
        #expect(first.index.count == 2)
        await first.closeAndWait()

        let restarted = try f.makeStore()
        defer { restarted.close() }
        #expect(restarted.stats().entries == 1)
        #expect(restarted.index.contains(tag16: try tag(f, restarted, position: 256)))
        #expect(!restarted.index.contains(tag16: try tag(f, restarted, position: 512)))
        #expect(restarted.config.epochStore?.current == epoch)
        #expect(restarted.prefixCacheV2Capability()?.cacheEpoch == epoch)
        #expect(restarted.takeNextPrefixCacheV2Sequence(expectedEpoch: epoch) == 2)
        let staged = await restarted.stage(requestID: .init(731), request: f.request(),
                                           reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(staged.staged)
        #expect(staged.stagedTokens == 256)
        await restarted.abandonStaging(requestID: .init(731))
        await restarted.closeAndWait()
    }

    @Test("a binding change still wipes the root, rotates, and disowns the superseded store")
    func bindingChangeStillRotates() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let store = try f.makeStore()
        defer { store.close() }
        #expect(try await f.donate(store) == [256])
        let epoch = try #require(store.config.epochStore?.current)
        let file = f.file(store)

        let successor = try SSDCacheEpochStore(root: f.modelRoot, binding: .init(
            modelId: "fixture-model", modelAggregateHash: f.identity.modelAggregateHash,
            promptContractId: f.identity.promptContractID, blockHashVersion: CBv2BlockHasher.version,
            blockSize: PrefixCachePolicy.blockSize, layoutEpoch: SSDHybridCheckpointEnvelope.layoutEpoch(
                identity: f.identity, backendLayout: f.backendLayout),
            keyFingerprint: "rotated-key"))
        let rotated = try #require(successor.current)
        #expect(rotated != epoch)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // The superseded store stops advertising and refuses per-file
        // removals, so it can never unlink the successor's files.
        #expect(store.config.epochStore?.current == nil)
        #expect(store.prefixCacheV2Capability() == nil)
        #expect(store.takeNextPrefixCacheV2Sequence(expectedEpoch: epoch) == nil)
        #expect(store.evictOldestEntry() == 0)
        #expect(store.index.count == 1, "a disowned store must not mutate the root")
        // Index-only reconciliation still runs for a disowned store.
        store.reconcileExternalRemovals()
        #expect(store.index.count == 0)
        #expect(store.diskBytesOnDisk == 0)
        await store.closeAndWait()
    }
}
