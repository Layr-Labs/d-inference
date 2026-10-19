import Foundation
import MLX
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

/// Regression for a write whose budget maintenance retires an older entry.
/// Uses only newly owned encrypted fixture roots.
@Suite("Checkpoint publication under same-store eviction", .serialized)
struct SSDCheckpointPublicationTests {
    final class Budget: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = 1 << 30
        func get() -> Int { lock.withLock { bytes } }
        func set(_ value: Int) { lock.withLock { bytes = value } }
    }

    final class Publications: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PrefixCacheReadyResult] = []
        func append(_ value: PrefixCacheReadyResult) { lock.withLock { values.append(value) } }
        var count: Int { lock.withLock { values.count } }
    }

    @Test("a surviving newly written checkpoint retains publication after older-entry eviction")
    func survivingWriteKeepsReady() async throws {
        let f = try SSDHybridCheckpointTestFixture(tokenCount: 1025)
        defer { f.remove() }
        let budget = Budget()
        let disk = SSDDiskBudget()
        let telemetry = PrefixCacheDonationTelemetry()
        let store = try f.makeStore(diskBudget: disk, diskBudgetBytes: { budget.get() }, donationRecorder: telemetry)
        defer { store.close() }
        #expect(try await f.donate(store, receipt: 10, position: 256) == [256])
        #expect(try await f.donate(store, receipt: 11, position: 512) == [512])
        let old = f.file(store, position: 256)
        let fresh = f.file(store, position: 512)
        let size = try #require((try FileManager.default.attributesOfItem(atPath: fresh.path)[.size]) as? Int)
        // Measure exact fixture geometry, then remove only the owned 512 entry.
        // Reconciliation completes before the measured donation starts.
        try FileManager.default.removeItem(at: fresh)
        disk.reconcileAll()
        #expect(store.index.count == 1)
        let oldTag = try #require(SSDPrefixCache.hexDecode(old.deletingPathExtension().lastPathComponent))
        store.index.touch(tags16: [oldTag], now: Int64(Date().timeIntervalSince1970) - 300)
        budget.set(size)

        let epoch = try #require(store.config.epochStore?.current)
        let published = Publications()
        store.registerReadyReceipt(requestID: .init(12), promptTokens: f.tokens, cacheScope: "tenant-a", callback: published.append)
        let before = telemetry.snapshot().first { $0.outcome == .cacheEpochChanged }?.count ?? 0
        let positions = try await f.donate(store, receipt: 12, position: 512)
        #expect(positions == [512])
        #expect(store.config.epochStore?.current == epoch)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(store.index.count == 1)
        let after = telemetry.snapshot().first { $0.outcome == .cacheEpochChanged }?.count ?? 0
        #expect(after == before)
        store.publishReady(requestID: .init(12), positions: [512])
        #expect(published.count == 1)

        // Independently distinguish unreadable/missing data from lost routing
        // evidence: the native encrypted-store stage must read the survivor.
        let stage = await store.stage(requestID: .init(13), request: f.request(),
            reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(stage.staged)
        #expect(stage.stagedTokens == 512)
        #expect(store.stats().filesRead > 0)
        await store.abandonStaging(requestID: .init(13))
        store.discardReadyReceipt(requestID: .init(12))
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
        print("CACHE_RETIREMENT surviving_new_checkpoint=512 ready_publication=present native_ssd_stage=success epoch=preserved")
    }
}
