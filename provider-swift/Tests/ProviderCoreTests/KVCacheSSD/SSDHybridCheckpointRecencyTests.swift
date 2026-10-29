import Foundation
import MLX
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Complete checkpoint coordinated recency retention", .serialized)
struct SSDHybridCheckpointRecencyTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: Int64 = 1000
        var now: Int64 { lock.withLock { seconds } }
        func advance(to value: Int64) { lock.withLock { seconds = value } }
    }

    private func makeStore(_ fixture: SSDHybridCheckpointTestFixture, clock: Clock, ttlSeconds: Int64 = 60,
                           diskBudget: SSDDiskBudget = SSDDiskBudget()) throws -> SSDHybridCheckpointStore {
        let epoch = try SSDCacheEpochStore(root: fixture.modelRoot, binding: .init(
            modelId: "fixture-model", modelAggregateHash: fixture.identity.modelAggregateHash,
            promptContractId: fixture.identity.promptContractID, blockHashVersion: CBv2BlockHasher.version,
            blockSize: PrefixCachePolicy.blockSize, layoutEpoch: SSDHybridCheckpointEnvelope.layoutEpoch(
                identity: fixture.identity, backendLayout: fixture.backendLayout), keyFingerprint: "fixture-key"))
        let store = SSDHybridCheckpointStore(config: .init(
            modelId: "fixture-model", identity: fixture.identity, backendLayout: fixture.backendLayout,
            root: fixture.modelRoot, dedicatedRoot: fixture.root, epochStore: epoch,
            maxReadBytes: 16 << 20, maxStageMillis: 1000, minEffectiveTokens: 256,
            ttlSeconds: ttlSeconds, strictFsync: false, nowSeconds: { clock.now },
            diskBudgetBytes: { 1 << 30 }, maintainWholeRoot: {}),
            kekKey: fixture.key, kvBudget: fixture.budget, diskBudget: diskBudget, maxWriteBytesPerDay: 1 << 30)
        store.scanOnDisk()
        return store
    }

    @Test("complete TTL characterization: expired indexed files refuse reads without waiting for a sweep",
          arguments: [1799, 1800, 1801])
    func ttlReadBoundaryWithoutSweep(age: Int) async throws {
        try await Device.withDefaultDevice(.cpu) {
            #expect(Device.defaultDevice().deviceType == .cpu)
            let fixture = try SSDHybridCheckpointTestFixture()
            defer {
                do { try FileManager.default.removeItem(at: fixture.root) }
                catch { Issue.record("complete expiry fixture cleanup failed: \(error)") }
            }
            let clock = Clock()
            let store = try makeStore(fixture, clock: clock, ttlSeconds: SSDPrefixCachePolicy.defaultTTLSeconds)
            do {
                let donated = try await fixture.donate(store)
                try #require(donated == [256], "donation setup must publish the fixture checkpoint")
                await store.waitForWritesForTesting()
                try #require(store.stats().entries == 1)
                try #require(store.index.oldest()?.lastAccess == 1000)
                try #require(store.stats().filesRead == 0)
                let file = fixture.file(store)
                let original = try Data(contentsOf: file)
                clock.advance(to: 1000 + Int64(age))
                let result = await store.stage(requestID: .init(510), request: fixture.request(),
                    reserveReadScratch: fixture.reserveReadScratch, makeImportPlan: fixture.plan)
                let expectedStage = Int64(age) < SSDPrefixCachePolicy.defaultTTLSeconds
                #expect(result.staged == expectedStage)
                #expect(store.stats().filesRead == (expectedStage ? 2 : 0))
                if expectedStage {
                    #expect(result.stagedTokens == 256)
                } else {
                    #expect(result.disposition == .missAbsent)
                    #expect(store.stats().stagedBytesInUse == 0)
                }
                // Eligibility refusal is separate from deletion: no sweep ran.
                #expect(store.stats().entries == 1)
                let retained = try Data(contentsOf: file)
                #expect(retained == original)
                await store.abandonStaging(requestID: .init(510))
            } catch {
                await store.closeAndWait()
                throw error
            }
            await store.closeAndWait()
            #expect(store.stats().stagedBytesInUse == 0)
            #expect(await fixture.budget.outstandingReservedBytes() == 0)
            #expect(fixture.codec.admission.bytesReserved == 0)
        }
    }

    @Test("a hit rewrites the file's mtime at most once per refresh interval, so receipts survive in between")
    func persistedRecencyInterval() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let clock = Clock()
        let store = try makeStore(fixture, clock: clock, ttlSeconds: SSDPrefixCachePolicy.defaultTTLSeconds)
        defer { store.close() }
        #expect(store.recencyRefreshSeconds == 60)
        #expect(try await fixture.donate(store) == [256])
        let file = fixture.file(store)
        func modified() throws -> Date? {
            try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        }
        func stage(_ identifier: UInt64, at seconds: Int64) async {
            clock.advance(to: seconds)
            #expect(await store.stage(requestID: .init(identifier), request: fixture.request(),
                reserveReadScratch: fixture.reserveReadScratch, makeImportPlan: fixture.plan).staged)
        }
        // The new file's wall-clock mtime is ahead of this clock, so it refreshes.
        await stage(601, at: 1000)
        #expect(try modified() == Date(timeIntervalSince1970: 1000))
        await stage(602, at: 1059)
        #expect(try modified() == Date(timeIntervalSince1970: 1000))
        #expect(store.index.oldest()?.lastAccess == 1059, "the in-memory index records every hit")
        #expect(try await fixture.donate(store, receipt: 601) == [256])
        #expect(store.stats().donationReadBytes == 0, "no touch since 601 recorded the file identity")
        await stage(603, at: 1060)
        #expect(try modified() == Date(timeIntervalSince1970: 1060))
        #expect(try await fixture.donate(store, receipt: 602) == [256])
        #expect(store.stats().donationReadBytes > 0, "603's refresh outdated 602's receipt")
        for identifier: UInt64 in [601, 602, 603] { await store.abandonStaging(requestID: .init(identifier)) }
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
    }

    @Test("whole-root TTL expiry keeps a file whose hits overlapped other reads and persists the last hit")
    func overlappedHitsSurviveWholeRootExpiry() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let clock = Clock()
        let ttl = SSDPrefixCachePolicy.defaultTTLSeconds
        // Registered with the shared budget, as production stores are, so
        // whole-root maintenance removes its files through it.
        let store = try makeStore(fixture, clock: clock, ttlSeconds: ttl, diskBudget: .shared)
        defer { store.close() }
        #expect(try await fixture.donate(store) == [256])
        let file = fixture.file(store)
        func modified() throws -> Date? {
            try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        }
        func stage(_ identifier: UInt64) async -> SSDPrefixCacheStageResult {
            await store.stage(requestID: .init(identifier), request: fixture.request(),
                              reserveReadScratch: fixture.reserveReadScratch, makeImportPlan: fixture.plan)
        }
        func sweep(at seconds: Int64) -> SSDWholeRootMaintainer.Result {
            defer { SSDDiskBudget.shared.reconcileAll() }
            return SSDWholeRootMaintainer().maintain(root: fixture.root, ttlSeconds: ttl,
                                                     nowSeconds: seconds, budgetBytes: 1 << 40)
        }
        // A lone hit persists its recency (the new file's wall-clock mtime is ahead of this clock).
        #expect(await stage(701).staged)
        #expect(try modified() == Date(timeIntervalSince1970: 1000))
        // The next hit overlaps another read of the file, which is then cancelled: no read touches it.
        clock.advance(to: 2000)
        let barrier = SSDCheckpointCoordinationTestSupport.Barrier()
        defer { barrier.release() }
        let overlapping = Task.detached {
            await store.stage(requestID: .init(702), request: fixture.request(), reserveReadScratch: fixture.reserveReadScratch) { manifest in
                try barrier.block()
                return try fixture.plan(manifest)
            }
        }
        defer { overlapping.cancel(); barrier.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { barrier.isEntered }
        #expect(await stage(703).staged)
        overlapping.cancel()
        barrier.release()
        #expect(await overlapping.value.disposition == .skippedPolicy)
        #expect(try modified() == Date(timeIntervalSince1970: 1000))
        #expect(store.index.oldest()?.lastAccess == 2000)
        // One TTL after the persisted hit, 801 s after the real one: the file stays and records 2000.
        clock.advance(to: 1000 + ttl + 1)
        #expect(sweep(at: 1000 + ttl + 1).ttlExpired == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try modified() == Date(timeIntervalSince1970: 2000))
        // A restart's scan now seeds recency from that hit.
        let restarted = try makeStore(fixture, clock: clock, ttlSeconds: ttl)
        #expect(restarted.stats().entries == 1 && restarted.index.oldest()?.lastAccess == 2000)
        await restarted.closeAndWait()
        // Expiry still follows the last hit: one TTL after it, the sweep removes the file.
        #expect(sweep(at: 2000 + ttl).ttlExpired == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        for identifier: UInt64 in [701, 703] { await store.abandonStaging(requestID: .init(identifier)) }
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
    }

    @Test("successful reads persist sliding TTL across restart without changing ciphertext or epoch")
    func slidingTTLAndRestart() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let clock = Clock()
        let first = try makeStore(fixture, clock: clock)
        defer { first.close() }
        #expect(try await fixture.donate(first) == [256])
        let file = fixture.file(first)
        let original = try Data(contentsOf: file)
        let epoch = first.config.epochStore?.current
        for (identifier, timestamp): (UInt64, Int64) in [(501, 1050), (502, 1090)] {
            clock.advance(to: timestamp)
            let result = await first.stage(requestID: .init(identifier), request: fixture.request(),
                                           reserveReadScratch: fixture.reserveReadScratch, makeImportPlan: fixture.plan)
            #expect(result.staged)
            await first.abandonStaging(requestID: .init(identifier))
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect(attributes[.modificationDate] as? Date == Date(timeIntervalSince1970: Double(timestamp)))
        }
        await first.closeAndWait()
        clock.advance(to: 1120)
        let restarted = try makeStore(fixture, clock: clock)
        defer { restarted.close() }
        #expect(restarted.stats().entries == 1)
        #expect(restarted.config.epochStore?.current == epoch)
        let restored = await restarted.stage(requestID: .init(503), request: fixture.request(),
                                             reserveReadScratch: fixture.reserveReadScratch, makeImportPlan: fixture.plan)
        #expect(restored.staged)
        #expect(try Data(contentsOf: file) == original)
        await restarted.closeAndWait()
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
        clock.advance(to: 1180)
        let expired = try makeStore(fixture, clock: clock)
        defer { expired.close() }
        #expect(expired.stats().entries == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(expired.stats().corruptDropped == 0, "an expired checkpoint is not a corrupt one")
        // TTL expiry at scan is a per-file removal: the epoch survives it.
        #expect(expired.config.epochStore?.current == epoch)
        await expired.closeAndWait()
    }

    @Test("a checkpoint that fails validation at startup is still counted as corrupt")
    func startupCorruptionStillCounts() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let clock = Clock()
        let first = try makeStore(fixture, clock: clock)
        #expect(try await fixture.donate(first) == [256])
        let file = fixture.file(first)
        await first.closeAndWait()
        try Data([0, 1, 2]).write(to: file)
        let restarted = try makeStore(fixture, clock: clock)
        defer { restarted.close() }
        #expect(restarted.stats().entries == 0)
        #expect(restarted.stats().corruptDropped == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        await restarted.closeAndWait()
    }
}
