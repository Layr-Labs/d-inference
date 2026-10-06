import Foundation
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

/// First-sight checkpoints at the store. A request whose only demand is the
/// coordinator's first-sight count writes speculatively: it yields to write
/// pressure, to a busy writer and to a full disk budget, always as
/// `write_speculative_limited`, while proven writes (a coordinator repeat, a
/// locally repeated tag, a request that restored from this store) fare
/// exactly as they do without first sight.
///
/// The fixture's cache lifetime is one hour, so the speculative headroom is
/// one twenty-fourth of the daily write cap.
@Suite("Speculative first-sight checkpoint writes", .serialized)
struct SSDCheckpointSpeculativeWriteTests {
    private static let cap = 1 << 30
    private static let novelShare = Int(Double(cap) * 0.9)
    private static let firstSight = SSDCheckpointDonationDemand(repeatedPrefixTokens: 0, firstSightTokens: 512)
    private static let coordinatorRepeat = SSDCheckpointDonationDemand(repeatedPrefixTokens: 512)

    /// The injected disk budget, changeable while a store is running.
    private final class DiskBudget: @unchecked Sendable {
        private let lock = NSLock()
        private var limit = 1 << 30
        var bytes: Int {
            get { lock.withLock { limit } }
            set { lock.withLock { limit = newValue } }
        }
    }

    /// What a donation's completion was called with; nil until it is called.
    private final class Settlement: @unchecked Sendable {
        private let lock = NSLock()
        private var settled: [Int]?
        var positions: [Int]? { lock.withLock { settled } }
        func settle(_ positions: [Int]) { lock.withLock { settled = positions } }
    }

    private func count(_ recorder: PrefixCacheDonationTelemetry, _ outcome: PrefixCacheDonationOutcome) -> UInt64 {
        recorder.snapshot().first { $0.outcome == outcome }?.count ?? 0
    }

    /// Repeated writes elsewhere have taken the total below the speculative
    /// floor (one twentieth is more than the headroom). The novel share is
    /// untouched, so a proven write still has all of today's budget.
    private func applyWritePressure(_ store: SSDHybridCheckpointStore) {
        #expect(store.rateLimiter.tryConsume(bytes: Self.cap / 20))
    }

    private func donate(
        _ fixture: SSDHybridCheckpointTestFixture, _ store: SSDHybridCheckpointStore,
        receipt: UInt64, position: Int, scope: String
    ) async throws -> [Int] {
        let source = try fixture.source(position: position, scope: scope)
        return await withCheckedContinuation { continuation in
            store.donate(source, requestID: .init(receipt), tokens: fixture.tokens, cacheSalt: scope) {
                continuation.resume(returning: $0)
            }
        }
    }

    @Test("a first-sight checkpoint with spare budget is written and charged to both buckets")
    func firstSightWritesWithSpareBudget() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(
            maxWriteBytesPerDay: Self.cap, donationRecorder: outcomes, writeNowSeconds: { 0 })
        defer { store.close() }
        store.registerDonationDemand(Self.firstSight, requestID: .init(30))
        #expect(try await fixture.donate(store, receipt: 30) == [256])
        #expect(count(outcomes, .donated) == 1)
        #expect(count(outcomes, .writeSpeculativeLimited) == 0)
        #expect(store.stats().filesWritten == 1)
        #expect(!store.rateLimiter.mightAccept(bytes: Self.cap))
        #expect(!store.rateLimiter.mightAccept(bytes: Self.novelShare, repeated: false))
        await store.closeAndWait()
    }

    @Test("a first-sight checkpoint under pressure settles write_speculative_limited before any I/O",
          arguments: [true, false])
    func firstSightUnderPressureYields(epochStore: Bool) async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(
            epoch: epochStore, maxWriteBytesPerDay: Self.cap, donationRecorder: outcomes,
            writeNowSeconds: { 0 })
        defer { store.close() }
        applyWritePressure(store)
        // No restore proof exists for this receipt, with or without an epoch
        // store, so nothing lifts it out of the speculative class.
        store.registerDonationDemand(Self.firstSight, requestID: .init(31))
        #expect(try await fixture.donate(store, receipt: 31).isEmpty)
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(count(outcomes, .donated) == 0)
        #expect(store.stats().filesWritten == 0)
        #expect(store.stats().entries == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.file(store).path))
        #expect(store.lock.withLock { store.writing.isEmpty })
        // Nothing was charged: what was left before the offer still is.
        #expect(store.rateLimiter.mightAccept(bytes: Self.cap - Self.cap / 20))
        #expect(store.rateLimiter.mightAccept(bytes: Self.novelShare, repeated: false))
        await store.closeAndWait()
    }

    @Test("a proven request's deeper checkpoint writes while the same store refuses first-sight checkpoints")
    func provenWritesUnderSpeculativePressure() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 1025)
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(
            maxWriteBytesPerDay: Self.cap, donationRecorder: outcomes, writeNowSeconds: { 0 })
        defer { store.close() }
        applyWritePressure(store)
        store.registerDonationDemand(Self.firstSight, requestID: .init(32))
        #expect(try await fixture.donate(store, receipt: 32, position: 256).isEmpty)
        // A coordinator repeat needs no local history on this store.
        store.registerDonationDemand(Self.coordinatorRepeat, requestID: .init(33))
        #expect(try await fixture.donate(store, receipt: 33, position: 768) == [768])
        store.registerDonationDemand(Self.firstSight, requestID: .init(34))
        #expect(try await fixture.donate(store, receipt: 34, position: 512).isEmpty)
        #expect(count(outcomes, .donated) == 1)
        #expect(count(outcomes, .writeSpeculativeLimited) == 2)
        #expect(store.stats().filesWritten == 1)
        await store.closeAndWait()
    }

    @Test("a coordinator repeat on a store with no local history keeps today's novel-share class")
    func coordinatorRepeatKeepsTheNovelShare() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(
            maxWriteBytesPerDay: Self.cap, donationRecorder: outcomes, writeNowSeconds: { 0 })
        defer { store.close() }
        #expect(store.rateLimiter.tryConsume(bytes: Self.novelShare, repeated: false))
        store.registerDonationDemand(Self.coordinatorRepeat, requestID: .init(35))
        #expect(try await fixture.donate(store, receipt: 35).isEmpty)
        #expect(count(outcomes, .writePriorityLimited) == 1)
        #expect(count(outcomes, .writeSpeculativeLimited) == 0)
        await store.closeAndWait()
    }

    @Test("a tag this store has seen before is a repeat even for a first-sight request")
    func locallyRepeatedTagIsProven() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(
            maxWriteBytesPerDay: Self.cap, donationRecorder: outcomes, writeNowSeconds: { 0 })
        defer { store.close() }
        applyWritePressure(store)
        store.registerDonationDemand(Self.firstSight, requestID: .init(36))
        #expect(try await fixture.donate(store, receipt: 36).isEmpty)
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        store.registerDonationDemand(Self.firstSight, requestID: .init(37))
        #expect(try await fixture.donate(store, receipt: 37) == [256])
        #expect(count(outcomes, .donated) == 1)
        // Charged as a repeat: the novel share is still whole.
        #expect(store.rateLimiter.mightAccept(bytes: Self.novelShare, repeated: false))
        await store.closeAndWait()
    }

    @Test("a first-sight request that restored from this store is not speculative")
    func restoredFirstSightIsProven() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 1025)
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(
            maxWriteBytesPerDay: Self.cap, donationRecorder: outcomes, writeNowSeconds: { 0 })
        defer { store.close() }
        store.registerDonationDemand(Self.coordinatorRepeat, requestID: .init(40))
        #expect(try await fixture.donate(store, receipt: 40, position: 256) == [256])
        applyWritePressure(store)
        // The next turn restores that checkpoint, but the coordinator has lost
        // its repeat history and sends first sight only.
        let restore = await store.stage(requestID: .init(41), request: fixture.request(),
            reserveReadScratch: fixture.reserveReadScratch, makeImportPlan: fixture.plan)
        #expect(restore.staged)
        store.registerDonationDemand(Self.firstSight, requestID: .init(41))
        #expect(try await fixture.donate(store, receipt: 41, position: 512) == [512])
        // A first-sight request that restored nothing stays speculative.
        store.registerDonationDemand(Self.firstSight, requestID: .init(42))
        #expect(try await fixture.donate(store, receipt: 42, position: 768).isEmpty)
        #expect(count(outcomes, .donated) == 2)
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        await store.abandonStaging(requestID: .init(41))
        await store.closeAndWait()
    }

    @Test("a restore proof from an earlier cache epoch does not lift a first-sight request out of the speculative class")
    func staleRestoreProofStaysSpeculative() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 1025)
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(
            maxWriteBytesPerDay: Self.cap, donationRecorder: outcomes, writeNowSeconds: { 0 })
        defer { store.close() }
        store.registerDonationDemand(Self.coordinatorRepeat, requestID: .init(43))
        #expect(try await fixture.donate(store, receipt: 43, position: 256) == [256])
        applyWritePressure(store)
        let restore = await store.stage(requestID: .init(44), request: fixture.request(),
            reserveReadScratch: fixture.reserveReadScratch, makeImportPlan: fixture.plan)
        #expect(restore.staged)
        #expect(store.config.epochStore?.rotate() != nil)
        store.registerDonationDemand(Self.firstSight, requestID: .init(44))
        #expect(try await fixture.donate(store, receipt: 44, position: 512).isEmpty)
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(store.stats().filesWritten == 1)
        await store.abandonStaging(requestID: .init(44))
        await store.closeAndWait()
    }

    @Test("a speculative offer that finds the writer busy settles write_speculative_limited; a proven write queues behind an in-flight speculative one; a second proven arrival then settles write_queue_full")
    func speculativeWritesNeedAnIdleWriter() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(
            maxWriteBytesPerDay: Self.cap, donationRecorder: outcomes, writeNowSeconds: { 0 })
        defer { store.close() }
        let provenInFlight = SSDCheckpointCoordinationTestSupport.Barrier()
        let speculativeInFlight = SSDCheckpointCoordinationTestSupport.Barrier()
        defer { provenInFlight.release(); speculativeInFlight.release() }
        let heldProvenFile = fixture.file(store, position: 256)
        let heldSpeculativeFile = fixture.file(store, position: 1024)
        store.lock.withLock {
            store.beforeWriteIndexForTesting = { url, _ in
                let barrier = url == heldProvenFile ? provenInFlight
                    : url == heldSpeculativeFile ? speculativeInFlight : nil
                do { try barrier?.block() } catch { Issue.record("writer barrier timed out: \(error)") }
            }
        }
        func offer(_ demand: SSDCheckpointDonationDemand, receipt: UInt64, position: Int) -> Task<[Int], any Error> {
            store.registerDonationDemand(demand, requestID: .init(receipt))
            return Task { try await fixture.donate(store, receipt: receipt, position: position) }
        }
        func writesInFlight() -> Int { store.lock.withLock { store.writing.count } }

        // A proven write is in flight.
        let heldProven = offer(Self.coordinatorRepeat, receipt: 50, position: 256)
        try await SSDCheckpointCoordinationTestSupport.waitUntil { provenInFlight.isEntered }
        // The speculative offer has all the budget it needs and is still
        // refused: it may not take the waiting slot.
        #expect(try await offer(Self.firstSight, receipt: 51, position: 512).value.isEmpty)
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(writesInFlight() == 1)
        // A proven offer takes that slot as it always has.
        let queuedProven = offer(Self.coordinatorRepeat, receipt: 52, position: 768)
        try await SSDCheckpointCoordinationTestSupport.waitUntil { writesInFlight() == 2 }
        provenInFlight.release()
        #expect(try await heldProven.value == [256])
        #expect(try await queuedProven.value == [768])
        #expect(count(outcomes, .writeQueueFull) == 0)

        // A speculative write is in flight in an otherwise idle writer.
        let heldSpeculative = offer(Self.firstSight, receipt: 53, position: 1024)
        try await SSDCheckpointCoordinationTestSupport.waitUntil { speculativeInFlight.isEntered }
        // One proven write waits behind that file.
        let provenBehindSpeculative = offer(Self.coordinatorRepeat, receipt: 54, position: 1280)
        try await SSDCheckpointCoordinationTestSupport.waitUntil { writesInFlight() == 2 }
        // The known residual: a second proven arrival in that window finds
        // the queue full, where behind a proven write it would have too.
        #expect(try await offer(Self.coordinatorRepeat, receipt: 55, position: 1536).value.isEmpty)
        #expect(count(outcomes, .writeQueueFull) == 1)
        #expect(try await offer(Self.firstSight, receipt: 56, position: 1792).value.isEmpty)
        #expect(count(outcomes, .writeSpeculativeLimited) == 2)
        #expect(count(outcomes, .writeQueueFull) == 1)
        speculativeInFlight.release()
        #expect(try await heldSpeculative.value == [1024])
        #expect(try await provenBehindSpeculative.value == [1280])
        #expect(count(outcomes, .donated) == 4)
        #expect(store.stats().filesWritten == 4)
        for refused in [512, 1536, 1792] {
            #expect(!FileManager.default.fileExists(atPath: fixture.file(store, position: refused).path))
        }
        await store.closeAndWait()
    }

    @Test("a speculative write that would exceed the disk budget is refused before I/O and evicts nothing")
    func speculativeWritesNeverEvict() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 1025)
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let diskBudget = DiskBudget()
        let store = try fixture.makeStore(
            maxWriteBytesPerDay: Self.cap, diskBudgetBytes: { diskBudget.bytes },
            donationRecorder: outcomes, writeNowSeconds: { 0 })
        defer { store.close() }
        store.registerDonationDemand(Self.coordinatorRepeat, requestID: .init(57))
        #expect(try await fixture.donate(store, receipt: 57, position: 256) == [256])
        // The cache now fills its disk budget exactly: any new file needs an eviction.
        diskBudget.bytes = store.stats().bytesOnDisk
        store.registerDonationDemand(Self.firstSight, requestID: .init(58))
        #expect(try await fixture.donate(store, receipt: 58, position: 512).isEmpty)
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(store.stats().filesWritten == 1)
        #expect(store.stats().entries == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.file(store, position: 256).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.file(store, position: 512).path))
        // The write budget is not what refused it: with room on disk a
        // first-sight checkpoint writes.
        diskBudget.bytes = 1 << 30
        store.registerDonationDemand(Self.firstSight, requestID: .init(59))
        #expect(try await fixture.donate(store, receipt: 59, position: 768) == [768])
        // A proven write is not held to the room rule: at a full disk budget
        // it is still written and enforcement evicts for it, as before.
        diskBudget.bytes = store.stats().bytesOnDisk
        store.registerDonationDemand(Self.coordinatorRepeat, requestID: .init(60))
        _ = try await fixture.donate(store, receipt: 60, position: 1024)
        #expect(store.stats().filesWritten == 3)
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        await store.closeAndWait()
    }

    /// The refusals of `prepareWriteJob`, each on its own: a speculative offer
    /// that cannot be written is turned away on the offering thread. It never
    /// becomes a job, so it does not occupy the idle writer while it waits
    /// for the file. The test holds the file's lease: an offer that had been
    /// queued would still be waiting on it when `donate` returns.
    @Test("a first-sight offer refused for write budget or for disk room is settled at admission and never takes the writer",
          arguments: [true, false])
    func admissionRefusalsNeverTakeTheWriter(diskRoomRefuses: Bool) async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let diskBudget = DiskBudget()
        let store = try fixture.makeStore(
            maxWriteBytesPerDay: Self.cap, diskBudgetBytes: { diskBudget.bytes },
            donationRecorder: outcomes, writeNowSeconds: { 0 })
        defer { store.close() }
        // Exactly one of the two admission checks can refuse.
        if diskRoomRefuses { diskBudget.bytes = 0 } else { applyWritePressure(store) }
        let file = fixture.file(store)
        let lease = store.fileCoordinator.makeAccess(to: file)
        try await lease.acquire()
        defer { lease.release() }
        store.registerDonationDemand(Self.firstSight, requestID: .init(63))
        let source = try fixture.source()
        let settlement = Settlement()
        store.donate(source, requestID: .init(63), tokens: fixture.tokens, cacheSalt: "tenant-a") {
            settlement.settle($0)
        }
        #expect(settlement.positions == [])
        #expect(store.fileCoordinator.pendingCount(for: file) == 0)
        #expect(store.lock.withLock { store.writing.isEmpty })
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(store.stats().filesWritten == 0)
        // Nothing was charged for the refused offer.
        #expect(store.rateLimiter.mightAccept(bytes: diskRoomRefuses ? Self.cap : Self.cap - Self.cap / 20))
        #expect(store.rateLimiter.mightAccept(bytes: Self.novelShare, repeated: false))
        lease.release()
        await store.closeAndWait()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    /// The writer's own disk-room check, the one before the charge. Admission
    /// found room, so only that check can refuse.
    @Test("a first-sight write admitted with disk room is refused before the charge when the room is gone by the time the writer runs")
    func diskRoomIsRecheckedBeforeTheCharge() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let earlier = try fixture.makeStore()
        earlier.registerDonationDemand(Self.coordinatorRepeat, requestID: .init(64))
        #expect(try await fixture.donate(earlier, receipt: 64, position: 256) == [256])
        await earlier.closeAndWait()

        // A restarted store: one entry on disk, both write buckets full.
        let outcomes = PrefixCacheDonationTelemetry()
        let diskBudget = DiskBudget()
        let store = try fixture.makeStore(
            maxWriteBytesPerDay: Self.cap, diskBudgetBytes: { diskBudget.bytes },
            donationRecorder: outcomes, writeNowSeconds: { 0 })
        defer { store.close() }
        #expect(store.stats().entries == 1)
        let file = fixture.file(store, position: 512)
        // Hold the new file's lease so the admitted job waits before the
        // writer reaches its checks.
        let lease = store.fileCoordinator.makeAccess(to: file)
        try await lease.acquire()
        defer { lease.release() }
        store.registerDonationDemand(Self.firstSight, requestID: .init(65))
        let offer = Task { try await fixture.donate(store, receipt: 65, position: 512) }
        try await SSDCheckpointCoordinationTestSupport.waitUntil {
            store.fileCoordinator.pendingCount(for: file) == 1
        }
        // Another store's write has meanwhile filled the shared disk budget:
        // any new file would now need an eviction.
        diskBudget.bytes = store.stats().bytesOnDisk
        lease.release()
        #expect(try await offer.value.isEmpty)
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(count(outcomes, .donated) == 0)
        #expect(store.stats().filesWritten == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // Nothing was evicted for it and nothing was charged.
        #expect(store.stats().entries == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.file(store, position: 256).path))
        #expect(store.rateLimiter.mightAccept(bytes: Self.cap))
        #expect(store.rateLimiter.mightAccept(bytes: Self.novelShare, repeated: false))
        await store.closeAndWait()
    }

    @Test("a first-sight offer whose durable entry is evicted before the write is charged as speculative")
    func evictedDurableDuplicateStaysSpeculative() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let earlier = try fixture.makeStore()
        earlier.registerDonationDemand(Self.coordinatorRepeat, requestID: .init(61))
        #expect(try await fixture.donate(earlier, receipt: 61) == [256])
        await earlier.closeAndWait()

        // The restarted store finds the checkpoint on disk and has no local
        // history of its tag, so the first-sight offer is a durable duplicate.
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(
            maxWriteBytesPerDay: Self.cap, donationRecorder: outcomes, writeNowSeconds: { 0 })
        defer { store.close() }
        #expect(store.stats().entries == 1)
        applyWritePressure(store)
        let file = fixture.file(store)
        let tag16 = try #require(SSDPrefixCache.hexDecode(file.deletingPathExtension().lastPathComponent))
        // Hold the file's lease so the accepted job waits before the writer
        // re-reads the index, and remove the entry in that window.
        let lease = store.fileCoordinator.makeAccess(to: file)
        try await lease.acquire()
        defer { lease.release() }
        store.registerDonationDemand(Self.firstSight, requestID: .init(62))
        let offer = Task { try await fixture.donate(store, receipt: 62) }
        try await SSDCheckpointCoordinationTestSupport.waitUntil {
            store.fileCoordinator.pendingCount(for: file) == 1
        }
        try FileManager.default.removeItem(at: file)
        store.forgetMissing(tag16)
        #expect(store.stats().entries == 0)
        lease.release()
        // Now a fresh write, it is judged as the speculative write it is.
        #expect(try await offer.value.isEmpty)
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(store.stats().filesWritten == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        await store.closeAndWait()
    }

    /// A durable duplicate skips every admission check, so when its entry is
    /// gone by the time the writer runs, the writer's disk-room check is the
    /// only one between a first-sight file and a full disk budget.
    @Test("a first-sight offer whose durable entry is evicted before the write is refused at a full disk budget with ample write budget")
    func evictedDurableDuplicateIsHeldToDiskRoom() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let earlier = try fixture.makeStore()
        earlier.registerDonationDemand(Self.coordinatorRepeat, requestID: .init(66))
        #expect(try await fixture.donate(earlier, receipt: 66) == [256])
        await earlier.closeAndWait()

        let outcomes = PrefixCacheDonationTelemetry()
        let diskBudget = DiskBudget()
        let store = try fixture.makeStore(
            maxWriteBytesPerDay: Self.cap, diskBudgetBytes: { diskBudget.bytes },
            donationRecorder: outcomes, writeNowSeconds: { 0 })
        defer { store.close() }
        #expect(store.stats().entries == 1)
        let file = fixture.file(store)
        let tag16 = try #require(SSDPrefixCache.hexDecode(file.deletingPathExtension().lastPathComponent))
        let lease = store.fileCoordinator.makeAccess(to: file)
        try await lease.acquire()
        defer { lease.release() }
        store.registerDonationDemand(Self.firstSight, requestID: .init(67))
        let offer = Task { try await fixture.donate(store, receipt: 67) }
        try await SSDCheckpointCoordinationTestSupport.waitUntil {
            store.fileCoordinator.pendingCount(for: file) == 1
        }
        try FileManager.default.removeItem(at: file)
        store.forgetMissing(tag16)
        #expect(store.stats().entries == 0)
        // The write budget is whole; the disk budget has no room at all.
        diskBudget.bytes = 0
        lease.release()
        #expect(try await offer.value.isEmpty)
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(store.stats().filesWritten == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(store.rateLimiter.mightAccept(bytes: Self.cap))
        #expect(store.rateLimiter.mightAccept(bytes: Self.novelShare, repeated: false))
        await store.closeAndWait()
    }

    @Test("one scope's first-sight flood leaves another scope's proven checkpoint writable")
    func firstSightFloodLeavesProvenWritesAlone() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let shallowestBytes = try SSDHybridCheckpointEnvelope(
            manifest: fixture.manifest(position: 256), maximumPlaintextBytes: 16 << 20).plaintextBytes
        // Headroom for one and a half of the shallowest checkpoint.
        let headroom = shallowestBytes * 3 / 2
        let cap = headroom * 24
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(
            maxWriteBytesPerDay: cap, donationRecorder: outcomes, writeNowSeconds: { 0 })
        defer { store.close() }
        // tenant-a offers eight distinct first-sight checkpoints.
        let positions = Array(stride(from: 256, through: 2048, by: 256))
        for (offset, position) in positions.enumerated() {
            let receipt = UInt64(80 + offset)
            store.registerDonationDemand(Self.firstSight, requestID: .init(receipt))
            _ = try await donate(fixture, store, receipt: receipt, position: position, scope: "tenant-a")
        }
        #expect(count(outcomes, .donated) == 1)
        #expect(count(outcomes, .writeSpeculativeLimited) == UInt64(positions.count - 1))
        // The bound: whatever the flood offers, it has taken at most the
        // headroom out of each bucket.
        #expect(store.rateLimiter.mightAccept(bytes: cap - headroom))
        #expect(store.rateLimiter.mightAccept(bytes: Int(Double(cap) * 0.9) - headroom, repeated: false))
        // tenant-b's proven checkpoint, the deepest and largest, still writes.
        store.registerDonationDemand(Self.coordinatorRepeat, requestID: .init(90))
        #expect(try await donate(fixture, store, receipt: 90, position: 2048, scope: "tenant-b") == [2048])
        #expect(count(outcomes, .donated) == 2)
        await store.closeAndWait()
    }
}
