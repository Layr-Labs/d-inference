import Foundation
import MLX
@testable import MLXLMCommon
import Testing

@testable import ProviderCore

/// The RAM-only tier on a real complete-checkpoint codec and admission
/// (`SSDHybridCheckpointTestFixture`), with no model weights.
@Suite("RAM-only checkpoint tier for memory_only requests", .serialized)
struct MemoryOnlyCheckpointTierTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64 = 1_000
        var now: Int64 { lock.withLock { value } }
        func advance(_ seconds: Int64) { lock.withLock { value += seconds } }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    static func marked(_ raw: UInt64) -> CBv2RequestID { CBv2RequestID(MemoryOnlyReceipt.bit | raw) }

    static func pool(budget: UInt64 = 1 << 30, ttl: Int64 = 1_800, ttlMode: SSDPrefixCachePolicy.TTLMode = .sliding,
                     clock: Clock = Clock()) -> MemoryOnlyCheckpointPool {
        let pool = MemoryOnlyCheckpointPool(ttlSeconds: ttl, ttlMode: ttlMode, nowSeconds: { clock.now })
        pool.setBudget(budget)
        return pool
    }

    static func tier(_ fixture: SSDHybridCheckpointTestFixture, pool: MemoryOnlyCheckpointPool,
                     wire: @escaping LockedHostRegion.Wire = { mlock($0, $1) }) -> MemoryOnlyCheckpointTier {
        MemoryOnlyCheckpointTier(
            config: .init(identity: fixture.identity, backendLayout: fixture.backendLayout, minEffectiveTokens: 256),
            kvBudget: fixture.budget, pool: pool, wire: wire)
    }

    /// Whether the donation was stored. The tier always completes with no
    /// positions: a RAM entry is not a durable commit.
    static func donate(_ tier: MemoryOnlyCheckpointTier, _ fixture: SSDHybridCheckpointTestFixture,
                       pool: MemoryOnlyCheckpointPool, receipt: CBv2RequestID?, position: Int = 256,
                       scope: String = "tenant-a") async throws -> Bool {
        let source = try fixture.source(position: position, scope: scope)
        let stored = pool.snapshot.stores[.stored] ?? 0
        let positions = await withCheckedContinuation { continuation in
            tier.donate(source, requestID: receipt, tokens: fixture.tokens, cacheSalt: scope) {
                continuation.resume(returning: $0)
            }
        }
        #expect(positions.isEmpty)
        return (pool.snapshot.stores[.stored] ?? 0) > stored
    }

    static func stage(_ tier: MemoryOnlyCheckpointTier, _ fixture: SSDHybridCheckpointTestFixture,
                      receipt: CBv2RequestID, scope: String = "tenant-a") async -> SSDPrefixCacheStageResult {
        let request = fixture.request(scope: scope)
        return await tier.stage(
            requestID: receipt, request: request,
            reserveReadScratch: { try fixture.reserveReadScratch() },
            makeImportPlan: { try fixture.codec.plan(manifest: $0, request: request) })
    }

    /// Every file under `root`, with its size and modification time.
    static func listing(_ root: URL) -> [String: [Double]] {
        var files: [String: [Double]] = [:]
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) ?? .init() {
            let values = try? url.resourceValues(forKeys: Set(keys))
            files[url.path] = [Double(values?.fileSize ?? -1),
                               values?.contentModificationDate?.timeIntervalSince1970 ?? -1]
        }
        return files
    }

    @Test("a marked request restores the second identical prefix from RAM")
    func markedDonationThenRestoreHits() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let pool = Self.pool()
        let tier = Self.tier(fixture, pool: pool)
        defer { tier.close() }

        #expect(await Self.stage(tier, fixture, receipt: Self.marked(1)).disposition == .missAbsent)
        #expect(try await Self.donate(tier, fixture, pool: pool, receipt: Self.marked(1)))
        let snapshot = pool.snapshot
        #expect(snapshot.entries == 1 && snapshot.bytes > 0 && snapshot.stores[.stored] == 1)

        let result = await Self.stage(tier, fixture, receipt: Self.marked(2))
        #expect(result.disposition == .staged(
            matchedTokens: 256, expectedPrefillTokensSaved: 256, shortenedByCorruption: false))
        #expect(result.tier == .memory && result.chainHashes.isEmpty)
        let lookup = result.resolved(actualCachedTokens: 256)
        #expect(lookup.tier == .memory && lookup.promptAnchor == nil && lookup.matchedAnchor == nil)
        let staged = try #require(tier.takeStaged(
            requestID: Self.marked(2), tokens: fixture.tokens, cacheSalt: "tenant-a",
            maximumSequenceLength: fixture.request().maxTokens + fixture.tokens.count))
        #expect(staged.manifest.position == 256 && staged.manifest.prefixTokens == Array(fixture.tokens.prefix(256)))
        staged.close()
        #expect(pool.snapshot.lookups[.hit] == 1 && pool.snapshot.hitTokens == 256)
    }

    @Test("an ordinary request's receipt is refused on every call, and nothing is stored")
    func unmarkedReceiptsAreRefused() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let pool = Self.pool()
        let tier = Self.tier(fixture, pool: pool)
        defer { tier.close() }

        #expect(!(try await Self.donate(tier, fixture, pool: pool, receipt: CBv2RequestID(1))))
        #expect(!(try await Self.donate(tier, fixture, pool: pool, receipt: nil)))
        #expect(try await Self.donate(tier, fixture, pool: pool, receipt: Self.marked(1)))
        let result = await Self.stage(tier, fixture, receipt: CBv2RequestID(2))
        #expect(result.disposition == .skippedPolicy && result.tier == .memory)
        #expect(pool.snapshot.unmarkedRefusals == 3 && pool.snapshot.entries == 1)
    }

    @Test("another scope never sees a marked entry")
    func otherScopeMisses() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let pool = Self.pool()
        let tier = Self.tier(fixture, pool: pool)
        defer { tier.close() }

        #expect(try await Self.donate(tier, fixture, pool: pool, receipt: Self.marked(1), scope: "tenant-a"))
        #expect(await Self.stage(tier, fixture, receipt: Self.marked(2), scope: "tenant-b").disposition == .missAbsent)
        #expect(await Self.stage(tier, fixture, receipt: Self.marked(3), scope: "tenant-a").staged)
    }

    /// A guard rather than a proof: the tier has no file API, so this fails
    /// only if one is added.
    @Test("the tier writes no file")
    func noFileIsWritten() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let before = Self.listing(fixture.root)
        let pool = Self.pool()
        let tier = Self.tier(fixture, pool: pool)
        #expect(try await Self.donate(tier, fixture, pool: pool, receipt: Self.marked(1)))
        #expect(await Self.stage(tier, fixture, receipt: Self.marked(2)).staged)
        tier.completeStaging(requestID: Self.marked(2))
        await tier.closeAndWait()
        #expect(Self.listing(fixture.root) == before)
    }

    @Test("closing the slot's tier (model unload) releases its entries")
    func closeReleasesEntries() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let pool = Self.pool()
        let tier = Self.tier(fixture, pool: pool)
        #expect(try await Self.donate(tier, fixture, pool: pool, receipt: Self.marked(1)))
        await tier.closeAndWait()
        #expect(pool.snapshot.entries == 0 && pool.bytesInUse == 0 && pool.snapshot.evictions[.unload] == 1)
        #expect(!(try await Self.donate(tier, fixture, pool: pool, receipt: Self.marked(2))))
        #expect(await Self.stage(tier, fixture, receipt: Self.marked(3)).disposition == .skippedPolicy)
    }

    @Test("pressure, a load, sleep, a shortfall and shutdown release every entry", arguments: [
        MemoryOnlyCheckpointPool.EvictionReason.pressure, .load, .sleep, .shutdown, .shortfall,
    ])
    func releaseAll(reason: MemoryOnlyCheckpointPool.EvictionReason) async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let pool = Self.pool()
        let tier = Self.tier(fixture, pool: pool)
        defer { tier.close() }
        #expect(try await Self.donate(tier, fixture, pool: pool, receipt: Self.marked(1)))
        pool.releaseAll(reason: reason)
        #expect(pool.snapshot.entries == 0 && pool.bytesInUse == 0 && pool.snapshot.evictions[reason] == 1)
        #expect(await Self.stage(tier, fixture, receipt: Self.marked(2)).disposition == .missAbsent)
    }

    @Test("over its budget the tier drops its least recently used entry")
    func leastRecentlyUsedEviction() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let probe = Self.pool()
        let measure = Self.tier(fixture, pool: probe)
        #expect(try await Self.donate(measure, fixture, pool: probe, receipt: Self.marked(1)))
        let entryBytes = probe.bytesInUse
        measure.close()

        let pool = Self.pool(budget: entryBytes * 2)
        let tier = Self.tier(fixture, pool: pool)
        defer { tier.close() }
        #expect(try await Self.donate(tier, fixture, pool: pool, receipt: Self.marked(2), scope: "a"))
        #expect(try await Self.donate(tier, fixture, pool: pool, receipt: Self.marked(3), scope: "b"))
        #expect(await Self.stage(tier, fixture, receipt: Self.marked(4), scope: "a").staged)  // "a" is now newest
        tier.completeStaging(requestID: Self.marked(4))
        #expect(try await Self.donate(tier, fixture, pool: pool, receipt: Self.marked(5), scope: "c"))
        #expect(pool.snapshot.entries == 2 && pool.snapshot.evictions[.lru] == 1)
        #expect(await Self.stage(tier, fixture, receipt: Self.marked(6), scope: "b").disposition == .missAbsent)
        #expect(await Self.stage(tier, fixture, receipt: Self.marked(7), scope: "a").staged)
    }

    @Test("an entry larger than the budget, or a budget of 0, is not stored")
    func budgetRefusal() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        // A whole page (16 KiB on Apple silicon) is more than either budget.
        for budget: UInt64 in [0, 4 << 10] {
            let pool = Self.pool(budget: budget)
            let tier = Self.tier(fixture, pool: pool)
            #expect(!(try await Self.donate(tier, fixture, pool: pool, receipt: Self.marked(1))))
            #expect(pool.snapshot.stores[.refusedBudget] == 1 && pool.bytesInUse == 0)
            tier.close()
        }
    }

    @Test("a donation the full queue can't take is settled at once")
    func fullQueueSettlesDonation() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let pool = Self.pool()
        let copying = CancelledPrefixBarrier()
        let gate = DispatchSemaphore(value: 0)
        // The first donation holds the queue's consumer inside wiring.
        let tier = Self.tier(fixture, pool: pool, wire: { copying.signal(); gate.wait(); return mlock($0, $1) })
        defer {
            for _ in 0..<5 { gate.signal() }
            tier.close()
        }
        func donate(_ n: UInt64, _ completion: @escaping @Sendable ([Int]) -> Void) throws {
            tier.donate(try fixture.source(position: 256, scope: "s\(n)"), requestID: Self.marked(n),
                        tokens: fixture.tokens, cacheSalt: "s\(n)", completion: completion)
        }
        try donate(1) { _ in }
        #expect(await copying.wait())
        for n in 2...5 { try donate(UInt64(n)) { _ in } }  // fills the 4-slot queue
        let settled = CancelledPrefixBarrier()
        try donate(6) { positions in
            #expect(positions.isEmpty)
            settled.signal()
        }
        #expect(await settled.wait(), "the refused donation's completion runs")
        #expect(pool.snapshot.stores[.refusedBusy] == 1)
    }

    @Test("a release while an entry is copied in keeps nothing")
    func releaseDuringCopy() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let pool = Self.pool()
        let copying = CancelledPrefixBarrier()
        let gate = DispatchSemaphore(value: 0)
        let tier = Self.tier(fixture, pool: pool, wire: { copying.signal(); gate.wait(); return mlock($0, $1) })
        defer { tier.close() }
        let settled = CancelledPrefixBarrier()
        tier.donate(try fixture.source(position: 256, scope: "tenant-a"), requestID: Self.marked(1),
                    tokens: fixture.tokens, cacheSalt: "tenant-a") { _ in settled.signal() }
        #expect(await copying.wait())
        pool.releaseAll(reason: .pressure)
        gate.signal()
        #expect(await settled.wait())
        #expect(pool.snapshot.entries == 0 && pool.bytesInUse == 0 && pool.snapshot.stores[.stored] == nil)
        #expect(pool.snapshot.evictions[.pressure] == 1)
        #expect(await Self.stage(tier, fixture, receipt: Self.marked(2)).disposition == .missAbsent)
    }

    @Test("closing waits for a restore still filling an import, which then stops")
    func closeWaitsForRestore() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let pool = Self.pool()
        let tier = Self.tier(fixture, pool: pool)
        #expect(try await Self.donate(tier, fixture, pool: pool, receipt: Self.marked(1)))
        let restoring = CancelledPrefixBarrier()
        let gate = DispatchSemaphore(value: 0)
        let request = fixture.request(scope: "tenant-a")
        let stage = Task {
            await tier.stage(
                requestID: Self.marked(2), request: request,
                reserveReadScratch: { restoring.signal(); gate.wait(); return try fixture.reserveReadScratch() },
                makeImportPlan: { try fixture.codec.plan(manifest: $0, request: request) })
        }
        #expect(await restoring.wait())
        let closed = Flag()
        let closing = Task {
            await tier.closeAndWait()
            closed.set()
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!closed.isSet, "the restore is still running")
        gate.signal()
        await closing.value
        #expect(!(await stage.value).staged)
        #expect(pool.snapshot.entries == 0 && pool.bytesInUse == 0)
    }

    @Test("an abandoned stage refunds its charge, and a cold retry of the request restores again")
    func abandonThenRetry() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let pool = Self.pool()
        let tier = Self.tier(fixture, pool: pool)
        defer { tier.close() }
        #expect(try await Self.donate(tier, fixture, pool: pool, receipt: Self.marked(1)))
        let charged = fixture.budget.processLedger.snapshot().chargedBytes
        #expect(await Self.stage(tier, fixture, receipt: Self.marked(2)).staged)
        await tier.abandonStaging(requestID: Self.marked(2))
        #expect(fixture.budget.processLedger.snapshot().chargedBytes == charged)
        #expect(await Self.stage(tier, fixture, receipt: Self.marked(2)).staged)
        let staged = try #require(tier.takeStaged(
            requestID: Self.marked(2), tokens: fixture.tokens, cacheSalt: "tenant-a",
            maximumSequenceLength: fixture.request().maxTokens + fixture.tokens.count))
        staged.close()
        #expect(pool.snapshot.lookups[.hit] == 2)
    }

    @Test("a re-donation of a held prefix copies nothing; a fixed TTL still counts from the first store", arguments: [
        SSDPrefixCachePolicy.TTLMode.sliding, .fixed,
    ])
    func duplicateDonation(ttlMode: SSDPrefixCachePolicy.TTLMode) async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let clock = Clock()
        let pool = Self.pool(ttl: 100, ttlMode: ttlMode, clock: clock)
        let tier = Self.tier(fixture, pool: pool)
        defer { tier.close() }
        #expect(try await Self.donate(tier, fixture, pool: pool, receipt: Self.marked(1)))
        let held = pool.bytesInUse
        clock.advance(60)
        #expect(!(try await Self.donate(tier, fixture, pool: pool, receipt: Self.marked(2))))
        #expect(pool.snapshot.stores[.duplicate] == 1 && pool.snapshot.stores[.stored] == 1)
        #expect(pool.snapshot.entries == 1 && pool.bytesInUse == held)
        clock.advance(41)
        let result = await Self.stage(tier, fixture, receipt: Self.marked(3))
        tier.completeStaging(requestID: Self.marked(3))
        // Sliding: the re-donation was a use. Fixed: 101 s after the store.
        #expect(result.staged == (ttlMode == .sliding))
    }

    @Test("the tier is offered to marked requests only with a budget, and not once closed")
    func availability() throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let pool = Self.pool(budget: 0)
        let tier = Self.tier(fixture, pool: pool)
        #expect(!tier.isAvailable)
        pool.setBudget(1 << 30)
        #expect(tier.isAvailable)
        tier.close()
        #expect(!tier.isAvailable)
    }

    @Test("pages that can't be wired are never kept unwired")
    func lockFailureStoresNothing() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let pool = Self.pool()
        let tier = Self.tier(fixture, pool: pool, wire: { _, _ in -1 })
        defer { tier.close() }
        #expect(!(try await Self.donate(tier, fixture, pool: pool, receipt: Self.marked(1))))
        #expect(pool.snapshot.stores[.refusedLock] == 1 && pool.snapshot.entries == 0 && pool.bytesInUse == 0)
        #expect(LockedHostRegion(bytes: 1 << 20, wire: { _, _ in -1 }) == nil)
    }

    @Test("sliding TTL restarts on reuse; fixed TTL counts from the store", arguments: [
        SSDPrefixCachePolicy.TTLMode.sliding, .fixed,
    ])
    func timeToLive(ttlMode: SSDPrefixCachePolicy.TTLMode) async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let clock = Clock()
        let pool = Self.pool(ttl: 100, ttlMode: ttlMode, clock: clock)
        let tier = Self.tier(fixture, pool: pool)
        defer { tier.close() }
        #expect(try await Self.donate(tier, fixture, pool: pool, receipt: Self.marked(1)))
        clock.advance(99)
        #expect(await Self.stage(tier, fixture, receipt: Self.marked(2)).staged)
        tier.completeStaging(requestID: Self.marked(2))
        clock.advance(51)
        let afterReuse = await Self.stage(tier, fixture, receipt: Self.marked(3))
        tier.completeStaging(requestID: Self.marked(3))
        #expect(afterReuse.staged == (ttlMode == .sliding))
        clock.advance(100)
        pool.sweepExpired()
        #expect(pool.snapshot.entries == 0 && pool.bytesInUse == 0 && pool.snapshot.evictions[.ttl] == 1)
    }

    @Test("an entry needs a whole budget of ledger headroom beside it")
    func headroomGuard() async throws {
        let ledger = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0, memorySnapshot: {
            .init(total: 3 << 30, active: 0, cache: 0, systemAvailable: 3 << 30)
        })
        let pool = Self.pool(budget: 2 << 30)
        #expect(pool.admit(bytes: 1 << 20, ledger: ledger) == nil)
        #expect(pool.snapshot.stores[.refusedHeadroom] == 1 && pool.bytesInUse == 0)
        #expect(ledger.processLedger.snapshot().chargedBytes == 0)
        pool.setBudget(512 << 20)
        let admission = try #require(pool.admit(bytes: 1 << 20, ledger: ledger))
        #expect(ledger.processLedger.snapshot().chargedBytes == admission.bytes)
        admission.cancel(outcome: .refusedPolicy)
        #expect(ledger.processLedger.snapshot().chargedBytes == 0 && pool.bytesInUse == 0)
    }

    @Test("a held entry is charged to the process ledger until it is released")
    func ledgerCharge() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let pool = Self.pool()
        let tier = Self.tier(fixture, pool: pool)
        let before = fixture.budget.processLedger.snapshot().chargedBytes
        #expect(try await Self.donate(tier, fixture, pool: pool, receipt: Self.marked(1)))
        #expect(fixture.budget.processLedger.snapshot().chargedBytes == before + pool.bytesInUse)
        await tier.closeAndWait()
        #expect(fixture.budget.processLedger.snapshot().chargedBytes == before)
    }
}
