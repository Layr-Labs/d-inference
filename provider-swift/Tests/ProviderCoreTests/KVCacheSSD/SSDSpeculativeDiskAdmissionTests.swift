import CryptoKit
import Foundation
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

/// A first-sight (speculative) checkpoint is granted only free disk budget.
/// These cases pin that it never makes an enforcement pass evict an entry
/// that was already there: not through the bytes its file adds over its
/// plaintext, not through another writer on the same budget, not through
/// bytes the registered indexes do not count, and not after it has been
/// published. Proven writes keep writing and evicting exactly as before.
///
/// Sizes: `plaintext` is what the write budget is charged; `file` is what the
/// disk budget is charged, the plaintext plus the header, the metadata and
/// each chunk's framing.
@Suite("Speculative disk admission", .serialized)
struct SSDSpeculativeDiskAdmissionTests {
    private static let firstSight = SSDCheckpointDonationDemand(repeatedPrefixTokens: 0, firstSightTokens: 512)
    private static let coordinatorRepeat = SSDCheckpointDonationDemand(repeatedPrefixTokens: 512)
    private typealias Support = SSDCheckpointCoordinationTestSupport

    /// The injected disk budget, changeable while a store is running.
    private final class DiskBudget: @unchecked Sendable {
        private let lock = NSLock()
        private var limit = 1 << 30
        var bytes: Int {
            get { lock.withLock { limit } }
            set { lock.withLock { limit = newValue } }
        }
    }

    private final class PassResults: @unchecked Sendable {
        private let lock = NSLock()
        private var evicted = 0
        var budgetEvicted: Int { lock.withLock { evicted } }
        func record(_ result: SSDWholeRootMaintainer.Result) { lock.withLock { evicted += result.budgetEvicted } }
    }

    private func count(_ recorder: PrefixCacheDonationTelemetry, _ outcome: PrefixCacheDonationOutcome) -> UInt64 {
        recorder.snapshot().first { $0.outcome == outcome }?.count ?? 0
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func fileBytes(_ url: URL) throws -> Int {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    }

    private func tempFiles(under root: URL) -> [String] {
        (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .map(\.lastPathComponent).filter { $0.contains(SSDBlockStore.tempMarker) }
    }

    private func file(
        _ fixture: SSDHybridCheckpointTestFixture, _ store: SSDHybridCheckpointStore, position: Int, scope: String
    ) -> URL {
        let chain = store.hashes(tokens: fixture.tokens, scope: scope)
        let tag = store.lookupKeys.checkpointTag(chainHash: chain[position / 256 - 1], cacheSalt: scope)
        return SSDBlockStore.fileURL(root: fixture.modelRoot, tag16Hex: Data(tag.prefix(16)).hexString)
    }

    private func donate(
        _ fixture: SSDHybridCheckpointTestFixture, _ store: SSDHybridCheckpointStore,
        _ demand: SSDCheckpointDonationDemand, receipt: UInt64, position: Int, scope: String = "tenant-a"
    ) async throws -> [Int] {
        store.registerDonationDemand(demand, requestID: .init(receipt))
        let source = try fixture.source(position: position, scope: scope)
        return await withCheckedContinuation { continuation in
            store.donate(source, requestID: .init(receipt), tokens: fixture.tokens, cacheSalt: scope) {
                continuation.resume(returning: $0)
            }
        }
    }

    /// Makes an entry the oldest by `seconds`, in the index (the active-store
    /// enforcer's order) and on disk (the whole-root pass's order).
    private func age(_ store: SSDHybridCheckpointStore, _ file: URL, by seconds: Int64) throws {
        let tag = try #require(SSDPrefixCache.hexDecode(file.deletingPathExtension().lastPathComponent))
        let then = Int64(Date().timeIntervalSince1970) - seconds
        store.index.touch(tags16: [tag], now: then)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: Double(then))], ofItemAtPath: file.path)
    }

    /// The plaintext and the stored size of the checkpoint at `position`,
    /// measured by writing it as a proven checkpoint in a store of its own.
    /// Both depend only on the fixture's identity, tokens and layout, so
    /// they carry over to every other fixture of the same shape.
    private func sizes(position: Int, paged: Bool = false) async throws -> (plaintext: Int, file: Int) {
        let probe = try SSDHybridCheckpointTestFixture(paged: paged, tokenCount: 2049)
        defer { probe.remove() }
        let store = try probe.makeStore(maxWriteBytesPerDay: 0)
        #expect(try await donate(probe, store, Self.coordinatorRepeat, receipt: 1, position: position) == [position])
        let plaintext = try SSDHybridCheckpointEnvelope(
            manifest: probe.manifest(position: position), maximumPlaintextBytes: 16 << 20).plaintextBytes
        let written = try fileBytes(probe.file(store, position: position))
        await store.closeAndWait()
        #expect(written > plaintext)
        return (plaintext, written)
    }

    /// Holds a store's writer after the named file is published and before
    /// it is indexed.
    private func hold(_ store: SSDHybridCheckpointStore, at file: URL) -> Support.Barrier {
        let barrier = Support.Barrier()
        store.lock.withLock {
            store.beforeWriteIndexForTesting = { url, _ in
                guard url == file else { return }
                do { try barrier.block() } catch { Issue.record("writer barrier timed out: \(error)") }
            }
        }
        return barrier
    }

    // MARK: Encryption and metadata overhead

    @Test("a first-sight checkpoint whose plaintext fits a nearly full disk budget but whose file does not is declined before I/O and evicts nothing",
          arguments: [false, true])
    func nearFullDiskDeclinesBeforeIO(oneByteShortOfTheFile: Bool) async throws {
        let next = try await sizes(position: 512)
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let disk = DiskBudget()
        let store = try fixture.makeStore(
            maxWriteBytesPerDay: 0, diskBudgetBytes: { disk.bytes }, donationRecorder: outcomes)
        defer { store.close() }
        #expect(try await donate(fixture, store, Self.coordinatorRepeat, receipt: 70, position: 256) == [256])
        let existing = fixture.file(store, position: 256)
        try age(store, existing, by: 300)
        disk.bytes = store.stats().bytesOnDisk + (oneByteShortOfTheFile ? next.file - 1 : next.plaintext)
        #expect(try await donate(fixture, store, Self.firstSight, receipt: 71, position: 512).isEmpty)
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(store.stats().filesWritten == 1)
        #expect(store.stats().entries == 1)
        #expect(store.stats().evictions == 0)
        #expect(exists(existing))
        #expect(!exists(fixture.file(store, position: 512)))
        #expect(tempFiles(under: fixture.root).isEmpty)
        #expect(store.lock.withLock { store.writing.isEmpty })
        await store.closeAndWait()
    }

    @Test("a first-sight checkpoint whose file fits the disk budget exactly is written and evicts nothing")
    func exactFitIsAdmitted() async throws {
        let next = try await sizes(position: 512)
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let disk = DiskBudget()
        let store = try fixture.makeStore(
            maxWriteBytesPerDay: 0, diskBudgetBytes: { disk.bytes }, donationRecorder: outcomes)
        defer { store.close() }
        #expect(try await donate(fixture, store, Self.coordinatorRepeat, receipt: 72, position: 256) == [256])
        let existing = store.stats().bytesOnDisk
        try age(store, fixture.file(store, position: 256), by: 300)
        disk.bytes = existing + next.file
        #expect(try await donate(fixture, store, Self.firstSight, receipt: 73, position: 512) == [512])
        #expect(count(outcomes, .writeSpeculativeLimited) == 0)
        #expect(store.stats().evictions == 0)
        #expect(store.stats().entries == 2)
        #expect(store.stats().bytesOnDisk == existing + next.file)
        #expect(try fileBytes(fixture.file(store, position: 512)) == next.file)
        await store.closeAndWait()
    }

    @Test("an empty store admits a first-sight checkpoint at its stored size and declines it one byte below",
          arguments: [(256, false), (1024, false), (2048, false), (256, true), (2048, true)])
    func storedSizeDecidesAnEmptyStore(position: Int, paged: Bool) async throws {
        let next = try await sizes(position: position, paged: paged)
        let fixture = try SSDHybridCheckpointTestFixture(paged: paged, tokenCount: 2049)
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let disk = DiskBudget()
        let store = try fixture.makeStore(
            maxWriteBytesPerDay: 0, diskBudgetBytes: { disk.bytes }, donationRecorder: outcomes)
        defer { store.close() }
        disk.bytes = next.file - 1
        #expect(try await donate(fixture, store, Self.firstSight, receipt: 74, position: position).isEmpty)
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(count(outcomes, .cacheEntryEvicted) == 0)
        #expect(store.stats().filesWritten == 0)
        #expect(tempFiles(under: fixture.root).isEmpty)
        // A second scope is a different checkpoint of the same size, with
        // no history in this store, so it is first sight as well.
        disk.bytes = next.file
        #expect(try await donate(
            fixture, store, Self.firstSight, receipt: 75, position: position, scope: "tenant-b") == [position])
        #expect(store.stats().bytesOnDisk == next.file)
        #expect(try fileBytes(file(fixture, store, position: position, scope: "tenant-b")) == next.file)
        #expect(store.stats().evictions == 0)
        await store.closeAndWait()
    }

    @Test("a first-sight offer whose durable entry is evicted before the write is held to its stored size")
    func evictedDurableDuplicateIsHeldToItsStoredSize() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let earlier = try fixture.makeStore(maxWriteBytesPerDay: 0)
        #expect(try await donate(fixture, earlier, Self.coordinatorRepeat, receipt: 76, position: 256) == [256])
        await earlier.closeAndWait()

        let outcomes = PrefixCacheDonationTelemetry()
        let disk = DiskBudget()
        let store = try fixture.makeStore(
            maxWriteBytesPerDay: 0, diskBudgetBytes: { disk.bytes }, donationRecorder: outcomes)
        defer { store.close() }
        #expect(store.stats().entries == 1)
        let file = fixture.file(store)
        let tag16 = try #require(SSDPrefixCache.hexDecode(file.deletingPathExtension().lastPathComponent))
        let lease = store.fileCoordinator.makeAccess(to: file)
        try await lease.acquire()
        defer { lease.release() }
        store.registerDonationDemand(Self.firstSight, requestID: .init(77))
        let offer = Task { try await fixture.donate(store, receipt: 77) }
        try await Support.waitUntil { store.fileCoordinator.pendingCount(for: file) == 1 }
        // The store removes the file and its entry together, as an eviction does.
        store.removeCorrupt(tag16)
        #expect(store.stats().entries == 0)
        // Room for the plaintext and not for the file.
        disk.bytes = try SSDHybridCheckpointEnvelope(
            manifest: fixture.manifest(), maximumPlaintextBytes: 16 << 20).plaintextBytes
        lease.release()
        #expect(try await offer.value.isEmpty)
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(count(outcomes, .cacheEntryEvicted) == 0)
        #expect(store.stats().filesWritten == 0)
        #expect(store.stats().maximumSegmentBytes == 0, "the writer read no tensor segment: it declined before I/O")
        #expect(!exists(file))
        await store.closeAndWait()
    }

    // MARK: Concurrent writers on one budget

    private struct Pair {
        let a = try! SSDHybridCheckpointTestFixture(tokenCount: 2049)
        let b = try! SSDHybridCheckpointTestFixture(tokenCount: 2049)
        let ledger = SSDDiskBudget()
        let disk = DiskBudget()
        let outcomesA = PrefixCacheDonationTelemetry()
        let outcomesB = PrefixCacheDonationTelemetry()
        func remove() { a.remove(); b.remove() }
    }

    /// Two model stores on one disk budget, each holding one older proven
    /// entry, with room left for exactly one more file of `room` bytes.
    private func stores(_ pair: Pair, room: Int) async throws -> (a: SSDHybridCheckpointStore, b: SSDHybridCheckpointStore) {
        let disk = pair.disk
        let a = try pair.a.makeStore(diskBudget: pair.ledger, maxWriteBytesPerDay: 0,
                                     diskBudgetBytes: { disk.bytes }, donationRecorder: pair.outcomesA)
        let b = try pair.b.makeStore(diskBudget: pair.ledger, maxWriteBytesPerDay: 0,
                                     diskBudgetBytes: { disk.bytes }, donationRecorder: pair.outcomesB)
        #expect(try await donate(pair.a, a, Self.coordinatorRepeat, receipt: 80, position: 512) == [512])
        #expect(try await donate(pair.b, b, Self.coordinatorRepeat, receipt: 81, position: 512) == [512])
        try age(a, pair.a.file(a, position: 512), by: 300)
        try age(b, pair.b.file(b, position: 512), by: 200)
        disk.bytes = pair.ledger.totalBytes + room
        return (a, b)
    }

    @Test("two model stores share room for one first-sight file: one is written, the other is declined before I/O, and neither store's older entry is evicted")
    func twoStoresOneRoom() async throws {
        let next = try await sizes(position: 256)
        let pair = Pair()
        defer { pair.remove() }
        let (a, b) = try await stores(pair, room: next.file)
        defer { a.close(); b.close() }
        let occupied = pair.ledger.totalBytes
        let held = hold(a, at: pair.a.file(a, position: 256))
        defer { held.release() }
        let first = Task { try await donate(pair.a, a, Self.firstSight, receipt: 82, position: 256) }
        try await Support.waitUntil { held.isEntered }
        // Store A's file is published and not yet indexed: no index counts it.
        #expect(try await donate(pair.b, b, Self.firstSight, receipt: 83, position: 256).isEmpty)
        #expect(count(pair.outcomesB, .writeSpeculativeLimited) == 1)
        #expect(b.stats().filesWritten == 1)
        #expect(!exists(pair.b.file(b, position: 256)))
        held.release()
        #expect(try await first.value == [256])
        #expect(exists(pair.a.file(a, position: 512)))
        #expect(exists(pair.b.file(b, position: 512)))
        #expect(pair.ledger.evictionCount == 0)
        #expect(pair.ledger.totalBytes == occupied + next.file)
        await a.closeAndWait()
        await b.closeAndWait()
    }

    @Test("a proven write that takes the room while a first-sight write is in flight in another store is written, and the first-sight write gives way without evicting")
    func provenArrivingWhileSpeculativeIsInFlight() async throws {
        let next = try await sizes(position: 256)
        let pair = Pair()
        defer { pair.remove() }
        let (a, b) = try await stores(pair, room: next.file)
        defer { a.close(); b.close() }
        let speculativeFile = pair.a.file(a, position: 256)
        let held = hold(a, at: speculativeFile)
        defer { held.release() }
        let speculative = Task { try await donate(pair.a, a, Self.firstSight, receipt: 84, position: 256) }
        try await Support.waitUntil { held.isEntered }
        #expect(try await donate(pair.b, b, Self.coordinatorRepeat, receipt: 85, position: 256) == [256])
        #expect(pair.ledger.evictionCount == 0)
        held.release()
        #expect(try await speculative.value.isEmpty)
        #expect(count(pair.outcomesA, .writeSpeculativeLimited) == 1)
        #expect(a.stats().filesWritten == 1)
        #expect(!exists(speculativeFile))
        #expect(tempFiles(under: pair.a.root).isEmpty)
        #expect(exists(pair.a.file(a, position: 512)))
        #expect(exists(pair.b.file(b, position: 512)))
        #expect(exists(pair.b.file(b, position: 256)))
        #expect(pair.ledger.evictionCount == 0)
        await a.closeAndWait()
        await b.closeAndWait()
    }

    @Test("a first-sight offer made while a proven write in another store is about to take the room is declined before I/O")
    func speculativeOfferedWhileProvenIsInFlight() async throws {
        let next = try await sizes(position: 256)
        let pair = Pair()
        defer { pair.remove() }
        let (a, b) = try await stores(pair, room: next.file)
        defer { a.close(); b.close() }
        let held = hold(b, at: pair.b.file(b, position: 256))
        defer { held.release() }
        let proven = Task { try await donate(pair.b, b, Self.coordinatorRepeat, receipt: 86, position: 256) }
        try await Support.waitUntil { held.isEntered }
        #expect(try await donate(pair.a, a, Self.firstSight, receipt: 87, position: 256).isEmpty)
        #expect(count(pair.outcomesA, .writeSpeculativeLimited) == 1)
        #expect(a.stats().filesWritten == 1)
        held.release()
        #expect(try await proven.value == [256])
        #expect(exists(pair.a.file(a, position: 512)))
        #expect(exists(pair.b.file(b, position: 512)))
        #expect(pair.ledger.evictionCount == 0)
        await a.closeAndWait()
        await b.closeAndWait()
    }

    // MARK: After the file is published

    @Test("a first-sight file whose room is gone after it was published is withdrawn instead of evicting an older entry")
    func budgetShrinksAfterPublish() async throws {
        let next = try await sizes(position: 512)
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let disk = DiskBudget()
        let store = try fixture.makeStore(
            maxWriteBytesPerDay: 0, diskBudgetBytes: { disk.bytes }, donationRecorder: outcomes)
        defer { store.close() }
        #expect(try await donate(fixture, store, Self.coordinatorRepeat, receipt: 88, position: 256) == [256])
        let existing = fixture.file(store, position: 256)
        try age(store, existing, by: 300)
        disk.bytes = store.stats().bytesOnDisk + next.file
        let speculativeFile = fixture.file(store, position: 512)
        let held = hold(store, at: speculativeFile)
        defer { held.release() }
        let speculative = Task { try await donate(fixture, store, Self.firstSight, receipt: 89, position: 512) }
        try await Support.waitUntil { held.isEntered }
        // Something else on the volume took one byte of the budget.
        disk.bytes -= 1
        held.release()
        #expect(try await speculative.value.isEmpty)
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(store.stats().evictions == 0)
        #expect(store.stats().entries == 1)
        #expect(exists(existing))
        #expect(!exists(speculativeFile))
        await store.closeAndWait()
    }

    @Test("a first-sight file published as its store closes or its epoch changes is removed, not left unindexed on disk",
          arguments: [true, false])
    func abandonedAfterPublishLeavesNoFile(close: Bool) async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(maxWriteBytesPerDay: 0, donationRecorder: outcomes)
        defer { store.close() }
        let speculativeFile = fixture.file(store)
        let held = hold(store, at: speculativeFile)
        defer { held.release() }
        let speculative = Task { try await donate(fixture, store, Self.firstSight, receipt: 90, position: 256) }
        try await Support.waitUntil { held.isEntered }
        if close { store.close() } else { #expect(store.config.epochStore?.rotate() != nil) }
        held.release()
        #expect(try await speculative.value.isEmpty)
        await store.closeAndWait()
        #expect(count(outcomes, close ? .cacheClosed : .cacheEpochChanged) == 1)
        #expect(!exists(speculativeFile))
        #expect(tempFiles(under: fixture.root).isEmpty)
        #expect(store.index.count == 0)
    }

    // MARK: Failed and cancelled writes give their room back

    /// A first-sight write in store A ended without a file. With room for
    /// exactly one more file over what the indexes hold, store B's is
    /// written only if A's write no longer holds any.
    private func expectRoomIsFree(_ pair: Pair, _ b: SSDHybridCheckpointStore, room: Int) async throws {
        pair.disk.bytes = pair.ledger.totalBytes + room
        #expect(try await donate(pair.b, b, Self.firstSight, receipt: 99, position: 256) == [256])
        #expect(count(pair.outcomesB, .writeSpeculativeLimited) == 0)
        #expect(pair.ledger.evictionCount == 0)
    }

    @Test("a first-sight write that fails gives its room back and leaves nothing on disk",
          arguments: [true, false])
    func failedWriteReleasesItsRoom(midStream: Bool) async throws {
        let next = try await sizes(position: 256)
        let pair = Pair()
        defer { pair.remove() }
        let (a, b) = try await stores(pair, room: next.file)
        defer { a.close(); b.close() }
        let target = pair.a.file(a, position: 256)
        if midStream {
            // The export is closed while the job waits for its file, so the
            // first tensor read fails after the manifest chunk was written.
            let lease = try #require(a.fileCoordinator.tryAcquire(to: target))
            a.registerDonationDemand(Self.firstSight, requestID: .init(91))
            let source = try pair.a.source(position: 256)
            let failed = Task {
                await withCheckedContinuation { (continuation: CheckedContinuation<[Int], Never>) in
                    a.donate(source, requestID: .init(91), tokens: pair.a.tokens, cacheSalt: "tenant-a") {
                        continuation.resume(returning: $0)
                    }
                }
            }
            try await Support.waitUntil { a.fileCoordinator.pendingCount(for: target) == 1 }
            source.close()
            lease.release()
            #expect(await failed.value.isEmpty)
        } else {
            // A directory at the target is rejected by no-follow I/O.
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            #expect(try await donate(pair.a, a, Self.firstSight, receipt: 91, position: 256).isEmpty)
            #expect(count(pair.outcomesA, .writeIOFailed) == 1)
        }
        #expect(count(pair.outcomesA, .donated) == 1)
        #expect(a.stats().filesWritten == 1)
        #expect(tempFiles(under: pair.a.root).isEmpty)
        #expect(a.lock.withLock { a.writing.isEmpty })
        try await expectRoomIsFree(pair, b, room: next.file)
        #expect(exists(pair.a.file(a, position: 512)))
        #expect(exists(pair.b.file(b, position: 512)))
        await a.closeAndWait()
        await b.closeAndWait()
    }

    @Test("a first-sight write cancelled by its store closing leaves its room free: queued for its file it has taken none, in flight it gives it back",
          arguments: [true, false])
    func closedWriteReleasesItsRoom(queued: Bool) async throws {
        let next = try await sizes(position: 256)
        let pair = Pair()
        defer { pair.remove() }
        let (a, b) = try await stores(pair, room: next.file)
        defer { a.close(); b.close() }
        let target = pair.a.file(a, position: 256)
        if queued {
            let lease = try #require(a.fileCoordinator.tryAcquire(to: target))
            defer { lease.release() }
            let cancelled = Task { try await donate(pair.a, a, Self.firstSight, receipt: 92, position: 256) }
            try await Support.waitUntil { a.fileCoordinator.pendingCount(for: target) == 1 }
            a.close()
            #expect(try await cancelled.value.isEmpty)
        } else {
            let held = hold(a, at: target)
            defer { held.release() }
            let cancelled = Task { try await donate(pair.a, a, Self.firstSight, receipt: 92, position: 256) }
            try await Support.waitUntil { held.isEntered }
            a.close()
            held.release()
            #expect(try await cancelled.value.isEmpty)
        }
        await a.closeAndWait()
        #expect(count(pair.outcomesA, .cacheClosed) == 1)
        #expect(!exists(target))
        #expect(tempFiles(under: pair.a.root).isEmpty)
        // Store A's older entry is still on disk. The two stores of this
        // test have a cache root each, so it is outside what store B is
        // held to; the probe below sets the budget from what is indexed now.
        #expect(exists(pair.a.file(a, position: 512)))
        try await expectRoomIsFree(pair, b, room: next.file)
        await b.closeAndWait()
    }

    // MARK: Bytes no registered index counts

    /// A store built as production builds it: registered with the shared
    /// budget, with the real whole-root pass after every write and once at
    /// start, after the scan.
    private func productionLikeStore(
        _ fixture: SSDHybridCheckpointTestFixture, disk: DiskBudget, outcomes: PrefixCacheDonationTelemetry,
        passes: PassResults
    ) -> SSDHybridCheckpointStore {
        let root = fixture.root
        let maintain: @Sendable () -> Void = {
            passes.record(SSDWholeRootMaintainer().maintain(
                root: root, ttlSeconds: 3600, nowSeconds: Int64(Date().timeIntervalSince1970),
                budgetBytes: disk.bytes))
        }
        // Other suites register stores with the shared budget while this
        // one runs. Their bytes are added to this store's budget, so the
        // room a test sets is the room of its own store. A write of
        // theirs in flight at the instant of a check here is not covered.
        let own = OwnBytes()
        let store = SSDHybridCheckpointStore(config: .init(
            modelId: "fixture-model", identity: fixture.identity, backendLayout: fixture.backendLayout,
            root: fixture.modelRoot, dedicatedRoot: fixture.root, epochStore: nil, maxReadBytes: 16 << 20,
            maxStageMillis: 1000, minEffectiveTokens: 256, ttlSeconds: 3600, strictFsync: false,
            nowSeconds: { Int64(Date().timeIntervalSince1970) },
            diskBudgetBytes: { disk.bytes + max(0, SSDDiskBudget.shared.totalBytes - own.bytes) },
            maintainWholeRoot: maintain),
            kekKey: fixture.key, kvBudget: fixture.budget, diskBudget: .shared, maxWriteBytesPerDay: 0,
            donationRecorder: outcomes)
        own.follow { [weak store] in store?.index.totalBytes ?? 0 }
        store.scanOnDisk()
        maintain()
        return store
    }

    /// What one store's index holds, read while the store runs.
    private final class OwnBytes: @unchecked Sendable {
        private let lock = NSLock()
        private var read: @Sendable () -> Int = { 0 }
        func follow(_ body: @escaping @Sendable () -> Int) { lock.withLock { read = body } }
        var bytes: Int { lock.withLock { read }() }
    }

    /// A readable checkpoint file of a model that is not loaded.
    private func unloadedModelFile(under root: URL, modifiedSecondsAgo: Int64) throws -> URL {
        let modelRoot = root.appendingPathComponent("111111111111", isDirectory: true)
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: modelRoot)
        let url = SSDBlockStore.fileURL(root: modelRoot, tag16Hex: String(repeating: "1", count: 32))
        let chunk = Data(repeating: 7, count: 4096)
        try SSDBlockStore.write(
            to: url,
            metadata: SSDBlockMetadata(
                lookupTag: String(repeating: "ab", count: 32), weightHash: "weight", layoutEpoch: "layout",
                blockSize: 8, layerCount: 1,
                chunks: [.init(layerIndex: 0, tensor: 0, shape: [1, 1, 1, 1], dtype: "float16")],
                chunkPlaintextSizes: [chunk.count], createdAt: 1),
            chunks: [chunk], kekKey: SymmetricKey(size: .bits256))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-Double(modifiedSecondsAgo))], ofItemAtPath: url.path)
        return url
    }

    @Test("a first-sight checkpoint is held to the bytes of unloaded models and of temp files, which only the whole-root pass counts",
          arguments: [true, false])
    func bytesOutsideEveryIndexCount(unloadedModel: Bool) async throws {
        let next = try await sizes(position: 512)
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        // On disk before the store starts, as after a model was unloaded or
        // a write was interrupted: neither is in any index.
        let outside: URL
        if unloadedModel {
            outside = try unloadedModelFile(under: fixture.root, modifiedSecondsAgo: 600)
        } else {
            let destination = SSDBlockStore.fileURL(
                root: fixture.root.appendingPathComponent("111111111111", isDirectory: true),
                tag16Hex: String(repeating: "1", count: 32))
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            outside = SSDBlockStore.temporaryFileURL(for: destination)
            try Data(repeating: 9, count: 4096).write(to: outside)
        }
        let outsideBytes = try fileBytes(outside)
        let outcomes = PrefixCacheDonationTelemetry()
        let disk = DiskBudget()
        let passes = PassResults()
        let store = productionLikeStore(fixture, disk: disk, outcomes: outcomes, passes: passes)
        defer { store.close() }
        #expect(try await donate(fixture, store, Self.coordinatorRepeat, receipt: 93, position: 256) == [256])
        let existing = fixture.file(store, position: 256)
        try age(store, existing, by: 300)
        // One byte short of holding the entry, the outside bytes and the file.
        disk.bytes = store.stats().bytesOnDisk + outsideBytes + next.file - 1
        #expect(try await donate(fixture, store, Self.firstSight, receipt: 94, position: 512).isEmpty)
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(store.stats().filesWritten == 1)
        #expect(passes.budgetEvicted == 0)
        #expect(store.stats().evictions == 0)
        #expect(exists(existing))
        #expect(exists(outside))
        #expect(!exists(fixture.file(store, position: 512)))
        await store.closeAndWait()
    }

    @Test("a whole-root pass that runs while a first-sight file is published and not yet indexed does not evict the older entry for it")
    func passDuringAnInFlightFirstSightFile() async throws {
        let next = try await sizes(position: 512)
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let disk = DiskBudget()
        let passes = PassResults()
        let store = productionLikeStore(fixture, disk: disk, outcomes: outcomes, passes: passes)
        defer { store.close() }
        #expect(try await donate(fixture, store, Self.coordinatorRepeat, receipt: 100, position: 256) == [256])
        let existing = fixture.file(store, position: 256)
        try age(store, existing, by: 300)
        disk.bytes = store.stats().bytesOnDisk + next.file
        let speculativeFile = fixture.file(store, position: 512)
        let held = hold(store, at: speculativeFile)
        defer { held.release() }
        let speculative = Task { try await donate(fixture, store, Self.firstSight, receipt: 101, position: 512) }
        try await Support.waitUntil { held.isEntered }
        // The pass another store, the block tier or the timer would run,
        // with one byte less than both files need.
        let result = SSDWholeRootMaintainer().maintain(
            root: fixture.root, ttlSeconds: 3600, nowSeconds: Int64(Date().timeIntervalSince1970),
            budgetBytes: disk.bytes - 1)
        #expect(result.budgetEvicted == 0)
        #expect(exists(existing))
        #expect(store.stats().entries == 1)
        held.release()
        // The room was short by one byte: the first-sight write gives way.
        #expect(try await speculative.value.isEmpty)
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(!exists(speculativeFile))
        #expect(exists(existing))
        #expect(passes.budgetEvicted == 0)
        #expect(store.stats().evictions == 0)
        await store.closeAndWait()
    }

    // MARK: Proven writes are unchanged

    @Test("a proven write at a nearly full disk budget is still written, and enforcement evicts the oldest entry for it")
    func provenNearFullStillWritesAndEvicts() async throws {
        let next = try await sizes(position: 512)
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let disk = DiskBudget()
        let store = try fixture.makeStore(
            maxWriteBytesPerDay: 0, diskBudgetBytes: { disk.bytes }, donationRecorder: outcomes)
        defer { store.close() }
        #expect(try await donate(fixture, store, Self.coordinatorRepeat, receipt: 95, position: 256) == [256])
        let existing = fixture.file(store, position: 256)
        try age(store, existing, by: 300)
        disk.bytes = store.stats().bytesOnDisk + next.plaintext
        #expect(try await donate(fixture, store, Self.coordinatorRepeat, receipt: 96, position: 512) == [512])
        #expect(count(outcomes, .donated) == 2)
        #expect(store.stats().filesWritten == 2)
        #expect(store.stats().evictions == 1)
        #expect(store.stats().entries == 1)
        #expect(!exists(existing))
        #expect(exists(fixture.file(store, position: 512)))
        await store.closeAndWait()
    }

    @Test("two proven writes in two stores with room for one are both written, with exactly one eviction, of the oldest entry")
    func twoProvenStoresEvictOnce() async throws {
        let next = try await sizes(position: 256)
        let pair = Pair()
        defer { pair.remove() }
        let (a, b) = try await stores(pair, room: next.file)
        defer { a.close(); b.close() }
        let held = hold(a, at: pair.a.file(a, position: 256))
        defer { held.release() }
        let first = Task { try await donate(pair.a, a, Self.coordinatorRepeat, receipt: 97, position: 256) }
        try await Support.waitUntil { held.isEntered }
        #expect(try await donate(pair.b, b, Self.coordinatorRepeat, receipt: 98, position: 256) == [256])
        #expect(pair.ledger.evictionCount == 0)
        held.release()
        #expect(try await first.value == [256])
        #expect(pair.ledger.evictionCount == 1)
        #expect(!exists(pair.a.file(a, position: 512)))
        #expect(exists(pair.b.file(b, position: 512)))
        #expect(exists(pair.a.file(a, position: 256)))
        #expect(exists(pair.b.file(b, position: 256)))
        #expect(count(pair.outcomesA, .donated) == 2)
        #expect(count(pair.outcomesB, .donated) == 2)
        await a.closeAndWait()
        await b.closeAndWait()
    }
}
