import Foundation
import Testing
@testable import ProviderCore

@Suite("Complete checkpoint maintenance epoch", .serialized)
struct SSDCheckpointMaintenanceEpochTests {
    @Test("missing oldest accounting satisfies the budget without evicting its survivor")
    func missingOldestPreservesSurvivor() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let budget = SSDDiskBudget()
        let store = try f.makeStore(diskBudget: budget)
        defer { store.close() }
        #expect(try await f.donate(store, position: 256) == [256])
        #expect(try await f.donate(store, position: 512) == [512])
        let missing = f.file(store, position: 256)
        let survivor = f.file(store, position: 512)
        let missingTag = try #require(SSDPrefixCache.hexDecode(missing.deletingPathExtension().lastPathComponent))
        let survivorTag = try #require(SSDPrefixCache.hexDecode(survivor.deletingPathExtension().lastPathComponent))
        let now = Int64(Date().timeIntervalSince1970)
        store.index.touch(tags16: [missingTag], now: now - 1)
        store.index.touch(tags16: [survivorTag], now: now)
        let bytes = try Data(contentsOf: survivor)
        let epoch = store.config.epochStore?.current
        let evictions = store.stats().evictions
        try FileManager.default.removeItem(at: missing)
        #expect(budget.enforce(budgetBytes: bytes.count) == 0)
        #expect(store.stats().evictions == evictions)
        #expect(store.index.totalBytes == bytes.count)
        #expect(store.index.contains(tag16: survivorTag))
        #expect(try Data(contentsOf: survivor) == bytes)
        #expect(store.config.epochStore?.current == epoch)
        let result = await store.stage(requestID: .init(991), request: f.request(),
            reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(result.stagedTokens == 512)
        await store.abandonStaging(requestID: .init(991))
        await store.closeAndWait()
    }

    @Test("reconciliation respects the same-tag writer lease and its fresh publication")
    func reconciliationPreservesRewrite() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let store = try f.makeStore()
        defer { store.close() }
        #expect(try await f.donate(store, position: 512) == [512])
        let file = f.file(store, position: 512)
        let tag = try #require(SSDPrefixCache.hexDecode(file.deletingPathExtension().lastPathComponent))
        let bytes = try Data(contentsOf: file)
        let lease = try #require(SSDCheckpointFileCoordinator.shared.tryAcquire(to: file))
        defer { lease.release() }
        // Hold the real writer's exclusion boundary across missing discovery,
        // recreation, and publication. Maintenance must defer a busy pathname.
        try FileManager.default.removeItem(at: file)
        store.reconcileExternalRemovals()
        #expect(store.index.contains(tag16: tag))
        try bytes.write(to: file)
        store.removalLock.withLock {
            store.index.insert(tag16: tag, fileBytes: bytes.count, lastAccess: Int64(Date().timeIntervalSince1970))
        }
        lease.release()
        store.reconcileExternalRemovals()
        #expect(store.index.contains(tag16: tag))
        #expect(store.index.totalBytes == bytes.count)
        let result = await store.stage(requestID: .init(992), request: f.request(),
            reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(result.stagedTokens == 512)
        await store.abandonStaging(requestID: .init(992))
        await store.closeAndWait()
    }

    @Test("whole-root TTL retirement preserves active survivor publication and reads")
    func activeTTLRetirementPreservesSurvivor() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let store = try f.makeStore(diskBudget: .shared)
        defer { store.close() }
        #expect(try await f.donate(store, position: 256) == [256])
        #expect(try await f.donate(store, position: 512) == [512])
        let epoch = try #require(store.config.epochStore?.current)
        let victim = f.file(store, position: 256), survivor = f.file(store, position: 512)
        let originalBytes = try Data(contentsOf: survivor)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: victim.path)
        let result = SSDWholeRootMaintainer().maintain(root: f.root, ttlSeconds: 3600,
            nowSeconds: Int64(Date().timeIntervalSince1970), budgetBytes: Int.max)
        #expect(result.ttlExpired == 1)
        SSDDiskBudget.shared.reconcileAll()
        #expect(store.config.epochStore?.current == epoch)
        #expect(store.prefixCacheV2Capability()?.cacheEpoch == epoch)
        #expect(store.index.count == 1)
        #expect(try Data(contentsOf: survivor) == originalBytes)
        let stage = await store.stage(requestID: .init(901), request: f.request(),
            reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(stage.staged && stage.stagedTokens == 512)
        await store.abandonStaging(requestID: .init(901))
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
    }

    @Test("budget eviction leaves unrelated entries for the explicit reconciliation pass, and neither rotates")
    func budgetEvictionDoesNotReconcileWholeIndex() async throws {
        let f = try SSDHybridCheckpointTestFixture(tokenCount: 1025)
        defer { f.remove() }
        let budget = SSDDiskBudget()
        let store = try f.makeStore(diskBudget: budget)
        defer { store.close() }
        var tags: [Data] = []
        for position in [256, 512, 768, 1024] {
            #expect(try await f.donate(store, position: position) == [position])
            let tag = try #require(SSDPrefixCache.hexDecode(
                f.file(store, position: position).deletingPathExtension().lastPathComponent))
            tags.append(tag)
            store.index.touch(tags16: [tag], now: Int64(Date().timeIntervalSince1970) - 1024 + Int64(position))
        }
        let bytes = try #require(store.index.fileBytes(tags16: tags[...]))
        // A separate filesystem mutation leaves an unrelated newest entry
        // stale. Single-entry budget eviction must touch only its victims;
        // the explicit reconcile pass owns discovery of other missing files.
        try FileManager.default.removeItem(at: f.file(store, position: 1024))
        let original = try #require(store.config.epochStore?.current)
        let limit = store.index.totalBytes - bytes[0] - bytes[1]
        #expect(budget.enforce(budgetBytes: limit) == 2)
        #expect(!store.index.contains(tag16: tags[0]))
        #expect(!store.index.contains(tag16: tags[1]))
        #expect(store.index.contains(tag16: tags[2]))
        #expect(store.index.contains(tag16: tags[3]))
        #expect(store.index.totalBytes == limit)
        // Two single-file evictions used to mint two epochs; the coordinator
        // must keep its evidence for the untouched 768-token checkpoint.
        #expect(store.config.epochStore?.current == original)
        budget.reconcileAll()
        #expect(store.index.count == 1)
        #expect(store.index.totalBytes == bytes[2])
        #expect(store.config.epochStore?.current == original)
        budget.reconcileAll()
        #expect(store.config.epochStore?.current == original)
        #expect(store.prefixCacheV2Capability()?.cacheEpoch == original)
        let result = await store.stage(requestID: .init(778), request: f.request(),
            reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(result.staged)
        await store.abandonStaging(requestID: .init(778))
        await store.closeAndWait()
    }

    @Test("owned deletion reconciles inside the barrier and a surviving checkpoint remains reusable")
    func ownedDeletionReconcilesWithoutRotation() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let budget = SSDDiskBudget()
        let store = try f.makeStore(diskBudget: budget)
        defer { store.close() }
        #expect(try await f.donate(store, position: 256) == [256])
        #expect(try await f.donate(store, position: 512) == [512])
        let original = try #require(store.config.epochStore?.current)
        let survivor = try Data(contentsOf: f.file(store, position: 256))
        let victim = f.file(store, position: 512)
        var removed = false
        let changed = budget.performActiveDestructiveChange(root: f.modelRoot) {
            removed = SSDBlockStore.removeItemIfSafe(at: victim, under: f.root)
        }
        #expect(changed == true)
        #expect(removed)
        #expect(store.config.epochStore?.current == original)
        #expect(store.prefixCacheV2Capability()?.cacheEpoch == original)
        #expect(store.index.count == 1)
        budget.reconcileAll()
        #expect(store.config.epochStore?.current == original)
        #expect(try Data(contentsOf: f.file(store, position: 256)) == survivor)
        let result = await store.stage(requestID: .init(777), request: f.request(),
            reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(result.staged)
        await store.abandonStaging(requestID: .init(777))
        await store.closeAndWait()
    }
}
