import Foundation
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

/// Speculative first-sight checkpoints (`cache_first_sight_tokens`): written
/// on their own bounded lane, inside a bounded share of the write budget and
/// without evicting another entry; proven writes never wait behind them.
@Suite("Speculative first-sight checkpoint writes", .serialized)
struct SSDSpeculativeFirstSightWriteTests {
    private typealias D = SSDCheckpointDonationDemand

    private func count(_ recorder: PrefixCacheDonationTelemetry, _ outcome: PrefixCacheDonationOutcome) -> UInt64 {
        recorder.snapshot().first { $0.outcome == outcome }?.count ?? 0
    }

    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        var current: Value {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    @Test("admission rule: only a coordinator admission covering the checkpoint")
    func rule() {
        #expect(SSDCheckpointDemand.admitsSpeculativeWrite(
            demand: D(repeatedPrefixTokens: 0, firstSightTokens: 1537), checkpointPosition: 1536, minEffectiveTokens: 1024))
        #expect(!SSDCheckpointDemand.admitsSpeculativeWrite(
            demand: D(repeatedPrefixTokens: 0, firstSightTokens: 1537), checkpointPosition: 1792, minEffectiveTokens: 1024))
        #expect(!SSDCheckpointDemand.admitsSpeculativeWrite(
            demand: D(repeatedPrefixTokens: 0, firstSightTokens: 512), checkpointPosition: 256, minEffectiveTokens: 1024))
        #expect(!SSDCheckpointDemand.admitsSpeculativeWrite(
            demand: D(repeatedPrefixTokens: 0), checkpointPosition: 256, minEffectiveTokens: 256))
        #expect(!SSDCheckpointDemand.admitsSpeculativeWrite(demand: nil, checkpointPosition: 256, minEffectiveTokens: 256))
        #expect(D(repeatedPrefixTokens: 0, firstSightTokens: -1).firstSightTokens == 0)
        let context = RemotePrefixCacheContext(
            cacheScope: "session-scope", cacheReceiptNonce: "n", repeatedPrefixTokens: 0, firstSightTokens: 1537)
        #expect(context.donationDemand == D(repeatedPrefixTokens: 0, firstSightTokens: 1537))
        // No repeat hint (older coordinator, standalone): legacy write-all, no admission needed.
        #expect(RemotePrefixCacheContext(cacheScope: "s", cacheReceiptNonce: nil, firstSightTokens: 1537)
            .donationDemand == nil)
    }

    @Test("an admitted first sight is written inside the speculative headroom")
    func admittedFirstSightWrites() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let cap = 1 << 30
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(maxWriteBytesPerDay: cap, donationRecorder: outcomes, writeNowSeconds: { 0 })
        defer { store.close() }
        store.registerDonationDemand(D(repeatedPrefixTokens: 0, firstSightTokens: 300), requestID: .init(30))
        #expect(try await fixture.donate(store, receipt: 30) == [256])
        #expect(count(outcomes, .donated) == 1)
        #expect(count(outcomes, .skippedNovel) == 0)
        let stats = store.stats()
        #expect(stats.speculativeFilesWritten == 1)
        #expect(stats.speculativeBytesWritten == stats.bytesWritten)
        #expect(FileManager.default.fileExists(atPath: fixture.file(store).path))
        // Proven writes keep everything outside the headroom.
        let headroom = Int(Double(cap) * SSDPrefixCachePolicy.speculativeHeadroomFraction(ttlSeconds: 3600))
        #expect(store.rateLimiter.mightAccept(bytes: cap - headroom, repeated: true))
        await store.closeAndWait()
    }

    @Test("without an admission, or once its headroom is spent, a novel checkpoint stays skipped and charges nothing")
    func headroomBounds() async throws {
        // Learn one file's serialized size, then size the headroom to hold
        // one file and not a second.
        let probe = try SSDHybridCheckpointTestFixture()
        defer { probe.remove() }
        let probeStore = try probe.makeStore()
        #expect(try await probe.donate(probeStore, receipt: 1) == [256])
        let fileBytes = probeStore.stats().bytesWritten
        await probeStore.closeAndWait()

        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let fraction = SSDPrefixCachePolicy.speculativeHeadroomFraction(ttlSeconds: 3600)
        let cap = Int((Double(fileBytes) * 1.5 / fraction).rounded(.up))
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(maxWriteBytesPerDay: cap, donationRecorder: outcomes, writeNowSeconds: { 0 })
        defer { store.close() }

        // Each donation uses its own scope (a distinct tag): a second local
        // sighting of one tag would pass the ordinary gate as a repeat.
        store.registerDonationDemand(D(repeatedPrefixTokens: 0), requestID: .init(31))
        #expect(try await fixture.startDonation(store, receipt: 31, scope: "tenant-c").value.isEmpty)
        #expect(count(outcomes, .skippedNovel) == 1)

        store.registerDonationDemand(D(repeatedPrefixTokens: 0, firstSightTokens: 256), requestID: .init(32))
        #expect(try await fixture.donate(store, receipt: 32) == [256])
        #expect(store.stats().speculativeFilesWritten == 1)

        // Another session's first sight no longer fits the headroom.
        store.registerDonationDemand(D(repeatedPrefixTokens: 0, firstSightTokens: 256), requestID: .init(33))
        #expect(try await fixture.startDonation(store, receipt: 33, scope: "tenant-b").value.isEmpty)
        #expect(count(outcomes, .skippedNovel) == 2)
        #expect(store.stats().speculativeRefusedBudget == 1)
        #expect(store.stats().filesWritten == 1)
        // The refusal charged nothing: a second charge would have taken the
        // bucket below cap minus one and a half files.
        #expect(store.rateLimiter.mightAccept(bytes: cap - fileBytes * 3 / 2, repeated: true))
        await store.closeAndWait()
    }

    @Test("an unlimited write cap admits no speculative write")
    func unlimitedCapRefuses() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(maxWriteBytesPerDay: 0, donationRecorder: outcomes)
        defer { store.close() }
        store.registerDonationDemand(D(repeatedPrefixTokens: 0, firstSightTokens: 256), requestID: .init(34))
        #expect(try await fixture.donate(store, receipt: 34).isEmpty)
        #expect(count(outcomes, .skippedNovel) == 1)
        #expect(store.stats().speculativeRefusedBudget == 1)
        await store.closeAndWait()
    }

    @Test("a speculative file never evicts another entry to fit the disk budget")
    func diskBudgetNeverEvicts() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 1025)
        defer { fixture.remove() }
        let limit = Box(1 << 30)
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(diskBudgetBytes: { limit.current }, donationRecorder: outcomes)
        defer { store.close() }
        store.registerDonationDemand(D(repeatedPrefixTokens: 4096), requestID: .init(35))
        #expect(try await fixture.donate(store, receipt: 35, position: 512) == [512])
        let proven = fixture.file(store, position: 512)
        limit.current = store.stats().bytesOnDisk
        store.registerDonationDemand(D(repeatedPrefixTokens: 0, firstSightTokens: 1024), requestID: .init(36))
        #expect(try await fixture.donate(store, receipt: 36, position: 256).isEmpty)
        #expect(count(outcomes, .skippedNovel) == 1)
        #expect(store.stats().speculativeRefusedDisk == 1)
        #expect(store.stats().evictions == 0)
        #expect(FileManager.default.fileExists(atPath: proven.path))
        await store.closeAndWait()
    }

    @Test("a speculative write leaves oldest-first whole-root maintenance to proven writes")
    func speculativeWriteSkipsWholeRootMaintenance() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 1025)
        defer { fixture.remove() }
        let maintained = Box(0)
        let store = try fixture.makeStore(maintainWholeRoot: { maintained.current += 1 })
        defer { store.close() }
        store.registerDonationDemand(D(repeatedPrefixTokens: 0, firstSightTokens: 1024), requestID: .init(43))
        #expect(try await fixture.donate(store, receipt: 43, position: 256) == [256])
        #expect(store.stats().speculativeFilesWritten == 1)
        #expect(maintained.current == 0)
        store.registerDonationDemand(D(repeatedPrefixTokens: 4096), requestID: .init(44))
        #expect(try await fixture.donate(store, receipt: 44, position: 512) == [512])
        #expect(maintained.current == 1)
        await store.closeAndWait()
    }

    @Test("a proven write never waits behind a speculative write")
    func provenWriteDoesNotWaitForSpeculative() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 1025)
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(donationRecorder: outcomes)
        defer { store.close() }
        let barrier = SSDCheckpointCoordinationTestSupport.Barrier()
        defer { barrier.release() }
        let held = Box(false)
        // Hold the speculative writer mid-file; the proven lane must not care.
        store.beforeWriteChunkForTesting = { index in
            guard index == 1, !held.current else { return }
            held.current = true
            try? barrier.block()
        }
        store.registerDonationDemand(D(repeatedPrefixTokens: 0, firstSightTokens: 1024), requestID: .init(37))
        let speculative = try fixture.startDonation(store, receipt: 37, position: 256)
        try await SSDCheckpointCoordinationTestSupport.waitUntil { barrier.isEntered }
        store.registerDonationDemand(D(repeatedPrefixTokens: 4096), requestID: .init(38))
        #expect(try await fixture.donate(store, receipt: 38, position: 512) == [512])
        #expect(store.lock.withLock { store.speculativeWriting.count } == 1)
        barrier.release()
        #expect(await speculative.value == [256])
        #expect(count(outcomes, .donated) == 2)
        #expect(store.stats().speculativeFilesWritten == 1)
        #expect(store.lock.withLock { store.speculativeWriting.isEmpty && store.writing.isEmpty })
        await store.closeAndWait()
    }

    @Test("a proven donation of a checkpoint queued as speculative makes that job proven")
    func provenDonationPromotesQueuedSpeculativeJob() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let cap = 1 << 30
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(maxWriteBytesPerDay: cap, donationRecorder: outcomes, writeNowSeconds: { 0 })
        defer { store.close() }
        // Hold the file so the speculative job waits before it charges anything.
        let file = fixture.file(store)
        let owner = store.fileCoordinator.makeAccess(to: file)
        try await owner.acquire()
        var held = true
        defer { if held { owner.release() } }
        store.registerDonationDemand(D(repeatedPrefixTokens: 0, firstSightTokens: 1024), requestID: .init(51))
        let speculative = try fixture.startDonation(store, receipt: 51)
        try await SSDCheckpointCoordinationTestSupport.waitUntil { store.fileCoordinator.pendingCount(for: file) == 1 }
        // Spend the whole speculative allowance: a speculative charge now fails.
        let headroom = Int(Double(cap) * SSDPrefixCachePolicy.speculativeHeadroomFraction(ttlSeconds: 3600))
        #expect(store.rateLimiter.consumeSpeculative(bytes: headroom) == .accepted)
        #expect(store.rateLimiter.consumeSpeculative(bytes: 1) == .priorityLimited)
        store.registerDonationDemand(D(repeatedPrefixTokens: 4096), requestID: .init(52))
        #expect(try await fixture.donate(store, receipt: 52).isEmpty)
        #expect(count(outcomes, .alreadyQueued) == 1)
        owner.release()
        held = false
        #expect(await speculative.value == [256])
        let stats = store.stats()
        #expect(stats.speculativePromoted == 1)
        #expect(stats.speculativeRefusedBudget == 0)
        #expect(stats.speculativeFilesWritten == 0)
        #expect(stats.filesWritten == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(store.lock.withLock { store.promotedSpeculative.isEmpty && store.speculativeWriting.isEmpty })
        await store.closeAndWait()
    }

    @Test("a full speculative lane refuses as skipped_novel and never touches the proven bound")
    func fullSpeculativeLaneRefuses() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 1025)
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(donationRecorder: outcomes)
        defer { store.close() }
        let barrier = SSDCheckpointCoordinationTestSupport.Barrier()
        defer { barrier.release() }
        let held = Box(false)
        store.beforeWriteChunkForTesting = { index in
            guard index == 1, !held.current else { return }
            held.current = true
            try? barrier.block()
        }
        let scopes = ["tenant-a", "tenant-b", "tenant-c"]
        for (offset, _) in scopes.enumerated() {
            store.registerDonationDemand(D(repeatedPrefixTokens: 0, firstSightTokens: 1024),
                                         requestID: .init(UInt64(40 + offset)))
        }
        let first = try fixture.startDonation(store, receipt: 40, position: 256, scope: scopes[0])
        try await SSDCheckpointCoordinationTestSupport.waitUntil { barrier.isEntered }
        let queued = try fixture.startDonation(store, receipt: 41, position: 256, scope: scopes[1])
        try await SSDCheckpointCoordinationTestSupport.waitUntil {
            store.lock.withLock { store.speculativeWriting.count } == SSDPrefixCachePolicy.speculativeWriteQueueMaxJobs
        }
        let refused = try fixture.startDonation(store, receipt: 42, position: 256, scope: scopes[2])
        #expect(await refused.value.isEmpty)
        #expect(store.stats().speculativeRefusedBusy == 1)
        #expect(store.lock.withLock { store.writing.isEmpty })
        barrier.release()
        #expect(await first.value == [256])
        #expect(await queued.value == [256])
        #expect(count(outcomes, .skippedNovel) == 1)
        #expect(count(outcomes, .writeQueueFull) == 0)
        await store.closeAndWait()
    }

    @Test("speculative bytes have their own daily ledger and never take the shared budget's last share")
    func speculativeLedgers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speculative-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = try SSDWriteBudget(root: root)
        let own = try SSDWriteBudget(root: root, fileName: SSDWriteBudget.speculativeFileName)
        let cap = 86_400_000
        let fraction = SSDPrefixCachePolicy.speculativeHeadroomFraction(ttlSeconds: 1800)
        let headroom = Int(Double(cap) * fraction)
        #expect(headroom == 1_800_000)
        let now = Box(0.0)
        func limiter() -> SSDWriteRateLimiter {
            SSDWriteRateLimiter(capBytesPerDay: cap, repeatReserveFraction: 0.1,
                                speculativeHeadroomFraction: fraction, writeBudget: shared,
                                speculativeBudget: own, nowSeconds: { now.current })
        }
        let first = limiter()
        #expect(first.consumeSpeculative(bytes: headroom) == .accepted)
        #expect(first.consumeSpeculative(bytes: 1) == .priorityLimited)
        // Proven and novel writes keep the rest of the cap; the total never exceeds it.
        #expect(first.consume(bytes: cap - headroom, repeated: true) == .accepted)
        #expect(first.consume(bytes: 1, repeated: true) == .rateLimited)
        // A new store build refills memory, not the persistent speculative ledger.
        now.current = 3_600
        #expect(limiter().consumeSpeculative(bytes: 1) == .priorityLimited)
        // A day later both ledgers have expired.
        now.current = 26 * 3_600
        let later = limiter()
        #expect(later.consumeSpeculative(bytes: headroom / 2) == .accepted)
        // Shared ledger nearly full from other writes: the last share stays theirs.
        #expect(later.consume(bytes: cap - headroom - headroom / 2 - 10, repeated: true) == .accepted)
        #expect(later.consumeSpeculative(bytes: 11) == .priorityLimited)
        #expect(later.consumeSpeculative(bytes: 10) == .accepted)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
            == [SSDWriteBudget.defaultFileName, SSDWriteBudget.speculativeFileName])
    }

    @Test("a refusal of an ordinary write for the total budget pauses speculative writes for a day")
    func totalBudgetRefusalPausesSpeculative() {
        let now = Box(0.0)
        let cap = 86_400_000
        let limiter = SSDWriteRateLimiter(capBytesPerDay: cap, repeatReserveFraction: 0.1,
                                          speculativeHeadroomFraction: 1800.0 / 86_400,
                                          nowSeconds: { now.current })
        #expect(limiter.speculativeAdmission(bytes: 1_000) == .accepted)
        #expect(limiter.consume(bytes: cap + 1, repeated: true) == .rateLimited)
        #expect(limiter.speculativeAdmission(bytes: 1_000) == .priorityLimited)
        now.current = 86_399
        #expect(limiter.consumeSpeculative(bytes: 1_000) == .priorityLimited)
        now.current = 86_401
        #expect(limiter.consumeSpeculative(bytes: 1_000) == .accepted)
    }

    private func ledgerRoot() throws -> (root: URL, ledger: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speculative-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, root.appendingPathComponent(SSDWriteBudget.defaultFileName))
    }

    @Test("a busy or failed ledger refuses an ordinary write without pausing speculative ones")
    func ledgerContentionDoesNotPause() throws {
        let (root, ledger) = try ledgerRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let limiter = SSDWriteRateLimiter(capBytesPerDay: 86_400_000, repeatReserveFraction: 0.1,
                                          speculativeHeadroomFraction: 1800.0 / 86_400,
                                          writeBudget: try SSDWriteBudget(root: root), nowSeconds: { 0 })
        let fd = open(ledger.path, O_RDWR)
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX) == 0)
        #expect(limiter.consume(bytes: 1_000, repeated: true) == .rateLimited)
        flock(fd, LOCK_UN)
        close(fd)
        #expect(limiter.speculativeAdmission(bytes: 1_000) == .accepted)
        #expect(limiter.consume(bytes: 1_000, repeated: true) == .accepted)
    }

    @Test("an ordinary charge waits out a speculative charge in this process instead of being refused")
    func ordinaryChargeWaitsForSpeculativeCharge() throws {
        let (root, ledger) = try ledgerRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let limiter = SSDWriteRateLimiter(capBytesPerDay: 86_400_000, repeatReserveFraction: 0.1,
                                          writeBudget: try SSDWriteBudget(root: root), nowSeconds: { 0 })
        let entered = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            // A speculative charge holding the root-wide ledger's file lock.
            SSDSpeculativeLedgerGate.process.speculative {
                let fd = open(ledger.path, O_RDWR)
                flock(fd, LOCK_EX)
                entered.signal()
                usleep(200_000)
                flock(fd, LOCK_UN)
                close(fd)
            }
            finished.signal()
        }
        #expect(entered.wait(timeout: .now() + 10) == .success)
        #expect(limiter.consume(bytes: 1_000, repeated: true) == .accepted)
        #expect(finished.wait(timeout: .now() + 10) == .success)
    }
}
