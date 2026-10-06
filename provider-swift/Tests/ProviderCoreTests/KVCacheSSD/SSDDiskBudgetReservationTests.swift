import CryptoKit
import Foundation
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

/// The ledger inside `SSDDiskBudget` and the pieces a speculative write's
/// disk admission is built from: the exact stored size, the budget's basis,
/// reservations, the whole-root pass's view of in-flight writes, and the
/// bytes no registered index counts.
@Suite("Disk budget reservations", .serialized)
struct SSDDiskBudgetReservationTests {
    private static let firstSight = SSDCheckpointDonationDemand(repeatedPrefixTokens: 0, firstSightTokens: 512)
    private static let coordinatorRepeat = SSDCheckpointDonationDemand(repeatedPrefixTokens: 512)
    private typealias Support = SSDCheckpointCoordinationTestSupport

    /// A registered store that holds `bytes` and never evicts.
    private final class StubStore: SSDEvictableStore, @unchecked Sendable {
        private let lock = NSLock()
        private var indexed: Int
        let evictionRoot: URL
        init(bytes: Int, root: URL) { indexed = bytes; evictionRoot = root }
        var bytes: Int {
            get { lock.withLock { indexed } }
            set { lock.withLock { indexed = newValue } }
        }
        var ownsEvictionRoot: Bool { true }
        var diskBytesOnDisk: Int { bytes }
        private var queuedBytes = 0
        /// Proven writes accepted and not started.
        var queued: Int {
            get { lock.withLock { queuedBytes } }
            set { lock.withLock { queuedBytes = newValue } }
        }
        var queuedWriteBytes: Int { queued }
        /// An entry exists but cannot be removed: enforcement tries once.
        func oldestEntryAccess() -> Int64? { 1 }
        func evictOldestEntry() -> Int { lock.withLock { attempts += 1 }; return 0 }
        private var attempts = 0
        var evictionAttempts: Int { lock.withLock { attempts } }
        func reconcileExternalRemovals() {}
        func performExternalDestructiveChange(_ body: () -> Void) -> Bool { false }
        func retireOwnedEntries(_ urls: [URL]) -> Set<String> { [] }
    }

    private final class DiskBudget: @unchecked Sendable {
        private let lock = NSLock()
        private var limit = 1 << 30
        var bytes: Int {
            get { lock.withLock { limit } }
            set { lock.withLock { limit = newValue } }
        }
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func add() { lock.withLock { value += 1 } }
    }

    private static let wholeRoot = URL(fileURLWithPath: "/tmp/darkbloom-ledger-\(UUID().uuidString)")
    private static let modelRoot = wholeRoot.appendingPathComponent("0123456789ab")
    private static var wholeRootKey: String { SSDDiskBudget.rootKey(wholeRoot) }

    /// A budget with one registered store holding 100 bytes.
    private func ledger() -> (SSDDiskBudget, StubStore) {
        let budget = SSDDiskBudget()
        let store = StubStore(bytes: 100, root: Self.modelRoot)
        budget.register(store)
        return (budget, store)
    }

    private func speculative(_ budget: SSDDiskBudget, _ bytes: Int, basis: SSDDiskBudgetBasis = .fixed(150),
                             key: String = "k") -> SSDDiskReservation? {
        budget.reserveSpeculative(bytes: bytes, keys: [key], wholeRootKey: Self.wholeRootKey, basis: basis)
    }

    private func proven(_ budget: SSDDiskBudget, _ bytes: Int, basis: SSDDiskBudgetBasis? = .fixed(150)) -> SSDDiskReservation {
        budget.registerProven(bytes: bytes, keys: ["p"], wholeRootKey: Self.wholeRootKey, basis: basis)
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

    private func donate(
        _ fixture: SSDHybridCheckpointTestFixture, _ store: SSDHybridCheckpointStore,
        _ demand: SSDCheckpointDonationDemand, receipt: UInt64, position: Int
    ) async throws -> [Int] {
        store.registerDonationDemand(demand, requestID: .init(receipt))
        return try await fixture.donate(store, receipt: receipt, position: position)
    }

    private func age(_ store: SSDHybridCheckpointStore, _ file: URL, by seconds: Int64) throws {
        let tag = try #require(SSDPrefixCache.hexDecode(file.deletingPathExtension().lastPathComponent))
        let then = Int64(Date().timeIntervalSince1970) - seconds
        store.index.touch(tags16: [tag], now: then)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: Double(then))], ofItemAtPath: file.path)
    }

    /// The exact stored size of the fixture's checkpoint at `position`,
    /// computed before any write from the metadata the writer will use.
    private func storedBytes(
        _ fixture: SSDHybridCheckpointTestFixture, _ store: SSDHybridCheckpointStore, position: Int
    ) throws -> Int {
        let envelope = try SSDHybridCheckpointEnvelope(
            manifest: fixture.manifest(position: position), maximumPlaintextBytes: 16 << 20)
        let chain = store.hashes(tokens: fixture.tokens, scope: "tenant-a")
        let tag = store.lookupKeys.checkpointTag(chainHash: chain[position / 256 - 1], cacheSalt: "tenant-a")
        return try SSDBlockStore.streamedFileBytes(for: envelope.metadata(
            tag: tag, identity: fixture.identity, createdAt: Int64(Date().timeIntervalSince1970),
            backendLayout: fixture.backendLayout))
    }

    // MARK: Budget basis

    @Test("a fixed budget does not move with writes; half of free drops by half of every byte still to land")
    func basisProjection() {
        #expect(SSDDiskBudgetBasis.fixed(150).bytes() == 150)
        #expect(SSDDiskBudgetBasis.fixed(150).bytes(afterWriting: 1 << 40) == 150)
        #expect(SSDDiskBudgetBasis.halfOfFree(freeBytes: 400).bytes() == 200)
        #expect(SSDDiskBudgetBasis.halfOfFree(freeBytes: 400).bytes(afterWriting: 100) == 150)
        #expect(SSDDiskBudgetBasis.halfOfFree(freeBytes: 400).bytes(afterWriting: 401) == 1)
        #expect(SSDDiskBudgetBasis.halfOfFree(freeBytes: 400).bytes(afterWriting: -5) == 200)
        #expect(SSDDiskBudgetBasis.halfOfFree(freeBytes: 0).bytes() == 1)
        #expect(SSDDiskBudgetBasis.halfOfFree(freeBytes: Int.max).bytes(afterWriting: Int.max) == 1)
        // Without bytes that are on the volume now and will be withdrawn.
        #expect(SSDDiskBudgetBasis.fixed(150).bytes(afterRemoving: 1 << 40) == 150)
        #expect(SSDDiskBudgetBasis.halfOfFree(freeBytes: 400).bytes(afterRemoving: 0) == 200)
        #expect(SSDDiskBudgetBasis.halfOfFree(freeBytes: 394).bytes(afterRemoving: 6) == 200)
        #expect(SSDDiskBudgetBasis.halfOfFree(freeBytes: 394).bytes(afterRemoving: -6) == 197)
        #expect(SSDDiskBudgetBasis.halfOfFree(freeBytes: Int.max).bytes(afterRemoving: Int.max) == Int.max / 2)
    }

    @Test("the policy's basis resolves to the same budget as before", arguments: [
        (["DARKBLOOM_PREFIX_CACHE_DISK_GB": "2"], Int?.some(1_000), SSDDiskBudgetBasis.fixed(2 << 30), 2_147_483_648),
        ([:], Int?.none, SSDDiskBudgetBasis.fixed(20 << 30), 21_474_836_480),
        ([:], Int?.some(1_000), SSDDiskBudgetBasis.halfOfFree(freeBytes: 1_000), 500),
        (["DARKBLOOM_PREFIX_CACHE_DISK_GB": "0"], Int?.some(1), SSDDiskBudgetBasis.halfOfFree(freeBytes: 1), 1),
    ] as [([String: String], Int?, SSDDiskBudgetBasis, Int)])
    func policyBasis(environment: [String: String], free: Int?, expected: SSDDiskBudgetBasis, bytes: Int) {
        #expect(PrefixCachePolicy.ssdDiskBudgetBasis(environment: environment, freeBytes: free) == expected)
        #expect(PrefixCachePolicy.ssdDiskBudgetBytes(environment: environment, freeBytes: free) == bytes)
    }

    // MARK: Ledger

    @Test("a speculative reservation is granted only free room and is released exactly once")
    func speculativeIsGrantedOnlyFreeRoom() throws {
        let (budget, _) = ledger()
        #expect(budget.hasSpeculativeRoom(bytes: 50, wholeRootKey: Self.wholeRootKey, basis: .fixed(150)))
        #expect(!budget.hasSpeculativeRoom(bytes: 51, wholeRootKey: Self.wholeRootKey, basis: .fixed(150)))
        #expect(budget.reservedBytesSnapshot == 0, "an advisory answer reserves nothing")
        #expect(speculative(budget, 51) == nil)
        #expect(speculative(budget, -1) == nil)
        #expect(speculative(budget, Int.max) == nil, "an overflowing sum is a refusal")
        let first = try #require(speculative(budget, 50))
        #expect(budget.reservedBytesSnapshot == 50)
        #expect(speculative(budget, 1, key: "other") == nil, "the room is taken while the first write is in flight")
        #expect(!budget.hasSpeculativeRoom(bytes: 1, wholeRootKey: Self.wholeRootKey, basis: .fixed(150)))
        budget.release(first, as: .discarded)
        budget.release(first, as: .committed)
        budget.release(first, as: .abandonedOnDisk)
        #expect(budget.reservedBytesSnapshot == 0)
        #expect(budget.unownedBytesSnapshot(wholeRootKey: Self.wholeRootKey) == 0, "a second release changes nothing")
        #expect(speculative(budget, 50) != nil)
    }

    @Test("of many simultaneous speculative requests for the same room exactly one is granted")
    func reservationIsAtomic() {
        let (budget, _) = ledger()
        let granted = Calls()
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            if speculative(budget, 50, key: "k\(index)") != nil { granted.add() }
        }
        #expect(granted.count == 1)
        #expect(budget.reservedBytesSnapshot == 50)
    }

    @Test("releasing a record whose size saturated the sum leaves the other records counted")
    func saturatedReleaseKeepsOtherRecords() throws {
        let (budget, _) = ledger()
        let held = proven(budget, 30)
        let huge = proven(budget, Int.max)
        #expect(budget.reservedBytesSnapshot == Int.max)
        budget.release(huge, as: .discarded)
        #expect(budget.reservedBytesSnapshot == 30)
        #expect(speculative(budget, 21) == nil, "100 + 30 + 21 against 150")
        budget.release(held, as: .discarded)
    }

    @Test("enforcement against half of free does not evict for bytes an in-flight speculative write has on the volume")
    func enforceCreditsSpeculativeBytesOnTheVolume() throws {
        let (budget, store) = ledger()
        // 100 indexed. Before the speculative write: free 200, budget 100.
        let inFlight = try #require(speculative(budget, 10, basis: .fixed(1 << 30)))
        // Its 10 bytes are on the volume: free 190, so half of free is 95.
        #expect(budget.enforce(basis: .halfOfFree(freeBytes: 190)) == 0)
        #expect(store.evictionAttempts == 1, "its landed bytes are not known yet, so the lower limit applies")
        inFlight.noteLanded(upTo: 10)
        #expect(budget.enforce(basis: .halfOfFree(freeBytes: 190)) == 0)
        #expect(store.evictionAttempts == 1, "(190 + 10) / 2 holds the 100 indexed bytes")
        // A proven write's bytes get no such credit, nor does a fixed budget move.
        let record = proven(budget, 10, basis: nil)
        record.noteLanded(upTo: 10)
        budget.release(inFlight, as: .discarded)
        _ = budget.enforce(basis: .halfOfFree(freeBytes: 190))
        #expect(store.evictionAttempts == 2)
        _ = budget.enforce(budgetBytes: 99)
        #expect(store.evictionAttempts == 3)
        budget.release(record, as: .discarded)
    }

    @Test("a proven write is indexed and released in one step; a store that deregistered meanwhile leaves the bytes counted as unowned")
    func provenCommit() throws {
        let (budget, store) = ledger()
        let committed = proven(budget, 40)
        #expect(budget.commitProven(committed, store: store) { store.bytes += 40; return true })
        #expect(budget.reservedBytesSnapshot == 0)
        #expect(budget.totalBytes == 140)
        #expect(budget.unownedBytesSnapshot(wholeRootKey: Self.wholeRootKey) == 0)

        let vanished = proven(budget, 40)
        #expect(!budget.commitProven(vanished, store: store) { false })
        #expect(budget.reservedBytesSnapshot == 0, "a file that is gone holds nothing")

        // The store closes with its 140 bytes on disk, then a write that
        // was in flight indexes one more file into it.
        let late = proven(budget, 25)
        budget.deregister(store)
        #expect(budget.commitProven(late, store: store) { true })
        #expect(budget.totalBytes == 0)
        #expect(budget.unownedBytesSnapshot(wholeRootKey: Self.wholeRootKey) == 165)
        // A writer with no store behind it: nothing to deregister.
        let block = proven(budget, 5)
        #expect(budget.commitProven(block, store: nil) { true })
        #expect(budget.unownedBytesSnapshot(wholeRootKey: Self.wholeRootKey) == 165)
        // A writer whose store is gone altogether: its index is summed by nobody.
        let orphan = proven(budget, 7)
        #expect(budget.commitProven(orphan, store: nil, storeIsKnown: true) { true })
        #expect(budget.unownedBytesSnapshot(wholeRootKey: Self.wholeRootKey) == 172)
        #expect(budget.reservedBytesSnapshot == 0)
    }

    @Test("proven writes that any store on the budget has accepted and not started are counted against a speculative write")
    func queuedProvenWorkCountsBoxWide() throws {
        let (budget, _) = ledger()
        let elsewhere = StubStore(bytes: 0, root: Self.wholeRoot.appendingPathComponent("ba9876543210"))
        budget.register(elsewhere)
        elsewhere.queued = 1
        #expect(!budget.hasSpeculativeRoom(bytes: 50, wholeRootKey: Self.wholeRootKey, basis: .fixed(150)))
        #expect(speculative(budget, 50) == nil, "100 indexed + 1 queued in another store + 50 against 150")
        let granted = try #require(speculative(budget, 49))
        budget.release(granted, as: .discarded)
        // Queued bytes are still to land, so they lower a half-of-free
        // budget too: 100 + 20 + S must fit (400 - 20 - S) / 2.
        elsewhere.queued = 20
        let basis = SSDDiskBudgetBasis.halfOfFree(freeBytes: 400)
        #expect(speculative(budget, 47, basis: basis) == nil)
        let fits = try #require(speculative(budget, 46, basis: basis))
        // The queued write starts: its exact bytes replace the bound.
        elsewhere.queued = 0
        let started = proven(budget, 20, basis: basis)
        #expect(!fits.isRevoked, "the same sum as before")
        budget.release(started, as: .discarded)
        budget.release(fits, as: .discarded)
        budget.deregister(elsewhere)
        #expect(budget.reservedBytesSnapshot == 0)
    }

    @Test("a proven write's exact bytes replace its queued bound in one step, so it is never counted twice against a speculative write in flight")
    func provenRecordReplacesItsQueuedBound() throws {
        let (budget, store) = ledger()
        let inFlight = try #require(speculative(budget, 30))
        // A proven write of 20 is accepted and not started: 100 + 30 + 20 fills 150.
        store.queued = 20
        let started = budget.registerProven(
            bytes: 20, keys: ["p"], wholeRootKey: Self.wholeRootKey, basis: .fixed(150),
            replacingQueued: { store.queued = 0 })
        #expect(store.queued == 0)
        #expect(!inFlight.isRevoked, "the same 150 as before it started")
        // Left in the queue's figure as well, the same write counts as 40.
        store.queued = 20
        budget.release(started, as: .discarded)
        let twice = budget.registerProven(bytes: 20, keys: ["p"], wholeRootKey: Self.wholeRootKey, basis: .fixed(150))
        #expect(inFlight.isRevoked)
        budget.release(twice, as: .discarded)
        budget.release(inFlight, as: .discarded)
    }

    @Test("a proven write that lands and is indexed between a speculative write's reading of the volume and its check cannot make the check pass")
    func checksCountBytesSettledSinceTheirReading() throws {
        let (budget, store) = ledger()
        // Half of free. 450 free with neither write on the volume.
        let late = try #require(speculative(budget, 50, basis: .halfOfFree(freeBytes: 450)))
        let record = proven(budget, 40, basis: nil)
        let inserts = Calls()
        let insert = { inserts.add(); return true }
        // Read with the speculative file on the volume and none of the
        // proven file: 400 free. The proven file then lands and is indexed
        // before the check takes the lock: 190 bytes against (400 - 40) / 2.
        let stale: () -> SSDDiskBudgetBasis = {
            _ = budget.commitProven(record, store: store) { store.bytes += 40; return true }
            return .halfOfFree(freeBytes: 400)
        }
        #expect(!budget.commitSpeculative(late, fileBytes: 50, basis: stale, insert: insert))
        #expect(inserts.count == 0)
        // A reading taken after the proven file was indexed has it on the volume.
        let short: () -> SSDDiskBudgetBasis = { .halfOfFree(freeBytes: 378) }
        #expect(!budget.mayPublishSpeculative(late, fileBytes: 50, basis: short))
        let enough: () -> SSDDiskBudgetBasis = { .halfOfFree(freeBytes: 380) }
        #expect(budget.mayPublishSpeculative(late, fileBytes: 50, basis: enough))
        // The publish check has the same reading-to-lock span.
        let again = proven(budget, 10, basis: nil)
        let stalePublish: () -> SSDDiskBudgetBasis = {
            _ = budget.commitProven(again, store: store) { store.bytes += 10; return true }
            return .halfOfFree(freeBytes: 400)
        }
        #expect(!budget.mayPublishSpeculative(late, fileBytes: 50, basis: stalePublish), "200 bytes against (400 - 10) / 2")
        let room: () -> SSDDiskBudgetBasis = { .halfOfFree(freeBytes: 400) }
        #expect(budget.commitSpeculative(late, fileBytes: 50, basis: room, insert: insert))
        #expect(inserts.count == 1)
        #expect(budget.reservedBytesSnapshot == 0)
    }

    @Test("a multi-block proven write is on the ledger exactly once from its start to its last block")
    func blocksAreClaimedFromOneDonationRecord() throws {
        let (budget, store) = ledger()
        // Three blocks of 10; the budget of 150 holds the 100 indexed bytes,
        // the donation and 20 more.
        let remainder = budget.registerProven(bytes: 30, keys: [], wholeRootKey: Self.wholeRootKey, basis: nil)
        #expect(speculative(budget, 21) == nil)
        let beside = try #require(speculative(budget, 20))
        let window = budget.beginWholeRootObservation()
        var sums: [Int] = []
        for name in ["b1", "b2"] {
            let record = budget.claimBlock(from: remainder, bytes: 10, keys: [name], basis: .fixed(150))
            sums.append(budget.totalBytes + budget.reservedBytesSnapshot)
            #expect(budget.commitProven(record, store: store) { store.bytes += 10; return true })
            sums.append(budget.totalBytes + budget.reservedBytesSnapshot)
        }
        #expect(sums == [150, 150, 150, 150], "indexed + reserved does not move as blocks are written")
        #expect(!beside.isRevoked)
        // The third block is skipped: its room is free again, and only its.
        budget.dropBlock(from: remainder, bytes: 10)
        #expect(budget.reservedBytesSnapshot == 20)
        #expect(budget.totalBytes == 120)
        let seen = budget.endWholeRootObservation(window)
        #expect(seen.reservedKeys == ["k", "b1", "b2"], "the donation's own record names no file")
        // A block that no longer fits beside a speculative write revokes
        // it; a caller that saw none in flight asks no budget.
        let again = budget.registerProven(bytes: 20, keys: [], wholeRootKey: Self.wholeRootKey, basis: nil)
        #expect(!beside.isRevoked, "the donation's record revokes nothing")
        let quiet = budget.claimBlock(from: again, bytes: 10, keys: ["b4"], basis: nil)
        #expect(!beside.isRevoked)
        let loud = budget.claimBlock(from: again, bytes: 10, keys: ["b5"], basis: .fixed(150))
        #expect(beside.isRevoked, "120 + 20 + 20 against 150")
        // Claiming more than the donation recorded cannot go below zero.
        budget.dropBlock(from: again, bytes: 1 << 20)
        for record in [quiet, loud, beside, again, remainder] { budget.release(record, as: .discarded) }
        #expect(budget.reservedBytesSnapshot == 0)
    }

    @Test("enforcement reads the volume again when a speculative write was withdrawn between its reading and the lock")
    func enforceReadsAgainAfterAWithdrawal() throws {
        let (budget, store) = ledger()
        // 100 indexed; free 200 without the speculative write's 10 bytes.
        let inFlight = try #require(speculative(budget, 10, basis: .fixed(1 << 30)))
        inFlight.noteLanded(upTo: 10)
        let readings = Calls()
        let stale: () -> SSDDiskBudgetBasis = {
            readings.add()
            guard readings.count == 1 else { return .halfOfFree(freeBytes: 200) }
            // Read with the 10 bytes on the volume; they are gone, with
            // their credit, before the limit is applied.
            budget.release(inFlight, as: .discarded)
            return .halfOfFree(freeBytes: 190)
        }
        #expect(budget.enforce(basis: stale) == 0)
        #expect(readings.count == 2)
        #expect(store.evictionAttempts == 0, "the stale reading of 95 was not enforced")

        // A write that was indexed took nothing off the volume.
        let kept = try #require(speculative(budget, 0, basis: .fixed(1 << 30)))
        let once = Calls()
        let indexed: () -> SSDDiskBudgetBasis = {
            once.add()
            budget.release(kept, as: .committed)
            return .fixed(100)
        }
        _ = budget.enforce(basis: indexed)
        #expect(once.count == 1)

        // Withdrawals at every reading: nothing is enforced in this call.
        let churn = Calls()
        let wholeRootKey = Self.wholeRootKey
        let churning: () -> SSDDiskBudgetBasis = {
            churn.add()
            if let passing = budget.reserveSpeculative(
                bytes: 0, keys: ["churn"], wholeRootKey: wholeRootKey, basis: .fixed(1 << 30)) {
                budget.release(passing, as: .discarded)
            }
            return .fixed(0)
        }
        #expect(budget.enforce(basis: churning) == 0)
        #expect(churn.count == 3)
        #expect(store.evictionAttempts == 0)
        let settled: () -> SSDDiskBudgetBasis = { .fixed(0) }
        _ = budget.enforce(basis: settled)
        #expect(store.evictionAttempts == 1)
    }

    @Test("a root has the same key before and after its directory exists, through a symbolic link")
    func rootKeyOfAPathNotYetCreated() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-rootkey-\(UUID().uuidString)", isDirectory: true)
        let real = base.appendingPathComponent("real", isDirectory: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let model = link.appendingPathComponent("cache/0123456789ab", isDirectory: true)
        let before = SSDDiskBudget.rootKey(model)
        let wholeBefore = SSDDiskBudget.wholeRootKey(ofModelRoot: model)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        #expect(SSDDiskBudget.rootKey(model) == before)
        #expect(SSDDiskBudget.wholeRootKey(ofModelRoot: model) == wholeBefore)
        #expect(before == real.resolvingSymlinksInPath().appendingPathComponent("cache/0123456789ab").path)
    }

    @Test("a proven write is never refused room, and revokes in-flight speculative writes only when the sum no longer fits")
    func provenIsNeverRefused() throws {
        let (budget, _) = ledger()
        let first = try #require(speculative(budget, 30))
        let small = proven(budget, 20)
        #expect(!first.isRevoked, "100 + 30 + 20 fits 150")
        let large = proven(budget, 1 << 40)
        #expect(first.isRevoked)
        #expect(!small.isRevoked && !large.isRevoked, "a proven write is never revoked")
        #expect(speculative(budget, 1, key: "other") == nil)
        budget.release(large, as: .discarded)
        budget.release(small, as: .committed)
        budget.release(first, as: .discarded)
        #expect(budget.reservedBytesSnapshot == 0)
        // A proven writer that saw no speculative write in flight asks no budget.
        #expect(!budget.hasSpeculativeReservations)
        let later = try #require(speculative(budget, 30))
        #expect(budget.hasSpeculativeReservations)
        _ = proven(budget, 1 << 40, basis: nil)
        #expect(!later.isRevoked, "nothing was asked, nothing revoked; the write's own publish check still decides")
        #expect(!budget.mayPublishSpeculative(later, fileBytes: 30, basis: .fixed(150)))
    }

    @Test("a speculative write is indexed and released in one step, only while its room still holds")
    func speculativeCommit() throws {
        let (budget, store) = ledger()
        let inserts = Calls()
        let insert = { inserts.add(); store.bytes += 50; return true }

        let committed = try #require(speculative(budget, 50))
        #expect(budget.mayPublishSpeculative(committed, fileBytes: 50, basis: .fixed(150)))
        #expect(budget.commitSpeculative(committed, fileBytes: 50, basis: .fixed(150), insert: insert))
        #expect(inserts.count == 1)
        #expect(budget.reservedBytesSnapshot == 0)
        #expect(budget.totalBytes == 150)

        store.bytes = 100
        let revoked = try #require(speculative(budget, 50))
        _ = proven(budget, 1)
        #expect(revoked.isRevoked)
        #expect(!budget.mayPublishSpeculative(revoked, fileBytes: 50, basis: .fixed(150)))
        #expect(!budget.commitSpeculative(revoked, fileBytes: 50, basis: .fixed(150), insert: insert))
        #expect(inserts.count == 1, "nothing is indexed for a revoked write")
        #expect(budget.reservedBytesSnapshot == 51, "the caller removes its file, then releases")
        budget.release(revoked, as: .discarded)

        let (shrinking, other) = ledger()
        let late = try #require(speculative(shrinking, 50))
        other.bytes = 101
        #expect(!shrinking.mayPublishSpeculative(late, fileBytes: 50, basis: .fixed(150)))
        #expect(!shrinking.commitSpeculative(late, fileBytes: 50, basis: .fixed(150), insert: insert))
        other.bytes = 100
        #expect(!shrinking.commitSpeculative(late, fileBytes: 50, basis: .fixed(149), insert: insert))
        #expect(!shrinking.commitSpeculative(late, fileBytes: 51, basis: .fixed(150), insert: insert),
                "the file's real length is what must fit")
        #expect(!shrinking.commitSpeculative(late, fileBytes: 50, basis: .fixed(150), insert: { false }),
                "a file that is gone is not indexed")
        other.queued = 1
        #expect(!shrinking.mayPublishSpeculative(late, fileBytes: 50, basis: .fixed(150)),
                "a proven write that a store has accepted and not started needs the room")
        #expect(!shrinking.commitSpeculative(late, fileBytes: 50, basis: .fixed(150), insert: insert))
        other.queued = 0
        #expect(shrinking.reservedBytesSnapshot == 50)
        #expect(shrinking.commitSpeculative(late, fileBytes: 50, basis: .fixed(150), insert: insert))
        #expect(shrinking.reservedBytesSnapshot == 0)
        #expect(!shrinking.commitSpeculative(late, fileBytes: 50, basis: .fixed(1 << 30), insert: insert),
                "a released reservation commits nothing")
    }

    @Test("with a budget of half the free bytes, a speculative write must fit the budget its own bytes leave")
    func halfOfFreeAdmission() throws {
        let (budget, _) = ledger()
        // Budget now 200, 100 indexed. A file of F bytes leaves (400 - F) / 2.
        let basis = SSDDiskBudgetBasis.halfOfFree(freeBytes: 400)
        #expect(speculative(budget, 67, basis: basis) == nil, "167 bytes against a budget of 166")
        let granted = try #require(speculative(budget, 66, basis: basis))
        // Its bytes have landed: free is 334, and they are on the volume.
        #expect(budget.mayPublishSpeculative(granted, fileBytes: 66, basis: .halfOfFree(freeBytes: 334)))
        // Another writer's bytes have not landed yet and lower the budget too.
        let other = proven(budget, 2, basis: .halfOfFree(freeBytes: 334))
        #expect(granted.isRevoked, "100 + 66 + 2 against (334 - 68) / 2")
        budget.release(other, as: .discarded)
        budget.release(granted, as: .discarded)
    }

    @Test("bytes no registered index counts stay in the occupancy: a closed store's files, an abandoned file, and what the whole-root pass publishes")
    func unownedBytes() throws {
        let (budget, store) = ledger()
        let key = Self.wholeRootKey
        budget.deregister(store)
        budget.deregister(store)
        #expect(budget.totalBytes == 0)
        #expect(budget.unownedBytesSnapshot(wholeRootKey: key) == 100, "its files are still on disk")
        #expect(speculative(budget, 51) == nil)
        #expect(budget.hasSpeculativeRoom(bytes: 150, wholeRootKey: "/another/root", basis: .fixed(150)),
                "another whole root is another tree")
        let abandoned = proven(budget, 10)
        budget.release(abandoned, as: .abandonedOnDisk)
        #expect(budget.unownedBytesSnapshot(wholeRootKey: key) == 110)

        // A pass that saw no change while it walked replaces the figure:
        // per model root, what is on disk less what a registered index holds.
        let successor = StubStore(bytes: 60, root: Self.modelRoot)
        budget.register(successor)
        var window = budget.beginWholeRootObservation()
        var seen = budget.endWholeRootObservation(window)
        budget.publishWholeRoot(
            wholeRootKey: key,
            bytesByModelRoot: [SSDDiskBudget.rootKey(Self.modelRoot): 100, "/tmp/unloaded": 7],
            unreservedTempBytes: 5, observation: seen)
        #expect(budget.unownedBytesSnapshot(wholeRootKey: key) == 40 + 7 + 5)

        // A pass that walked across a commit, a registration or a close
        // would miss bytes that changed sides, so it publishes nothing.
        window = budget.beginWholeRootObservation()
        budget.release(proven(budget, 1), as: .committed)
        seen = budget.endWholeRootObservation(window)
        budget.publishWholeRoot(
            wholeRootKey: key, bytesByModelRoot: [:], unreservedTempBytes: 0, observation: seen)
        #expect(budget.unownedBytesSnapshot(wholeRootKey: key) == 52, "such a pass does not lower the figure")
        window = budget.beginWholeRootObservation()
        budget.release(proven(budget, 1), as: .committed)
        seen = budget.endWholeRootObservation(window)
        budget.publishWholeRoot(
            wholeRootKey: key, bytesByModelRoot: ["/tmp/unloaded": 70], unreservedTempBytes: 0, observation: seen)
        #expect(budget.unownedBytesSnapshot(wholeRootKey: key) == 70, "it may raise it")
        // A root that cannot be listed cannot lower the figure.
        let missing = URL(fileURLWithPath: key)
        _ = SSDWholeRootMaintainer().maintain(
            root: missing, ttlSeconds: 3600, nowSeconds: 0, budgetBytes: 1 << 30, budget: budget)
        #expect(budget.unownedBytesSnapshot(wholeRootKey: key) == 70)
        // Nor can a walk that could not list everything; it can raise it.
        for (found, expected) in [(10, 70), (90, 90), (10, 90)] {
            window = budget.beginWholeRootObservation()
            seen = budget.endWholeRootObservation(window)
            budget.publishWholeRoot(
                wholeRootKey: key, bytesByModelRoot: ["/tmp/unloaded": found], unreservedTempBytes: 0,
                observation: seen, complete: false)
            #expect(budget.unownedBytesSnapshot(wholeRootKey: key) == expected)
        }
        window = budget.beginWholeRootObservation()
        seen = budget.endWholeRootObservation(window)
        budget.publishWholeRoot(
            wholeRootKey: key, bytesByModelRoot: ["/tmp/unloaded": 10], unreservedTempBytes: 0, observation: seen)
        #expect(budget.unownedBytesSnapshot(wholeRootKey: key) == 10, "the next whole pass sets it")
    }

    @Test("a whole-root observation names every reservation outstanding at any time in its window")
    func observationWindow() throws {
        let (budget, _) = ledger()
        let before = try #require(speculative(budget, 10, key: "before"))
        let window = budget.beginWholeRootObservation()
        let during = try #require(speculative(budget, 10, key: "during"))
        let provenDuring = budget.registerProven(
            bytes: 1, keys: ["proven"], wholeRootKey: Self.wholeRootKey, basis: .fixed(150))
        budget.release(before, as: .discarded)
        budget.release(during, as: .discarded)
        let seen = budget.endWholeRootObservation(window)
        let after = try #require(speculative(budget, 10, key: "after"))
        #expect(seen.speculativeKeys == ["before", "during"])
        #expect(seen.reservedKeys == ["before", "during", "proven"])
        budget.release(provenDuring, as: .discarded)
        budget.release(after, as: .discarded)
    }

    @Test("a whole-root observation reports the bytes speculative writes had on the volume in its window, without the ones that were indexed")
    func observationReportsSpeculativeBytesOnTheVolume() throws {
        let (budget, _) = ledger()
        let basis = SSDDiskBudgetBasis.fixed(1 << 30)
        let window = budget.beginWholeRootObservation()
        let withdrawn = try #require(speculative(budget, 10, basis: basis, key: "withdrawn"))
        withdrawn.noteLanded(upTo: 7)
        let indexed = try #require(speculative(budget, 10, basis: basis, key: "indexed"))
        indexed.noteLanded(upTo: 10)
        let writing = try #require(speculative(budget, 10, basis: basis, key: "writing"))
        writing.noteLanded(upTo: 3)
        let record = proven(budget, 10, basis: nil)
        record.noteLanded(upTo: 10)
        // Withdrawn before the walk reaches its directory: its bytes were
        // on the volume when the pass read the free figure all the same.
        budget.release(withdrawn, as: .discarded)
        budget.release(indexed, as: .committed)
        let seen = budget.endWholeRootObservation(window)
        #expect(seen.speculativeLandedBytes == 10, "7 withdrawn + 3 still writing")
        budget.release(writing, as: .discarded)
        budget.release(record, as: .discarded)
        let quiet = budget.endWholeRootObservation(budget.beginWholeRootObservation())
        #expect(quiet.speculativeLandedBytes == 0)
    }

    // MARK: Stored size

    @Test("the stored size computed before any I/O equals the bytes written and the file's length", arguments: [
        ([1], Int64(1), "weights"),
        ([257, 4096], Int64(1), "weights"),
        ([0, 9, 10, 999_999, 1_000_000], Int64(9_999_999_999), "weights"),
        (Array(repeating: 33, count: 129), Int64(10_000_000_000), "w\"\\\n/é"),
        ([4 << 20, 1], Int64.min, String(repeating: "h", count: 512)),
        ([], Int64.max, ""),
    ] as [([Int], Int64, String)])
    func storedSizeIsExact(sizes: [Int], createdAt: Int64, weightHash: String) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ssd-stored-size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("0123456789ab")
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: model)
        let file = SSDBlockStore.fileURL(root: model, tag16Hex: String(repeating: "a", count: 32))
        let metadata = SSDBlockMetadata(
            lookupTag: String(repeating: "a", count: 64), weightHash: weightHash, layoutEpoch: "stored-size",
            blockSize: 256, layerCount: 1,
            chunks: sizes.enumerated().map {
                .init(layerIndex: 0, tensor: $0.offset, shape: [$0.element], dtype: "uint8")
            }, chunkPlaintextSizes: sizes, createdAt: createdAt)
        let predicted = try SSDBlockStore.streamedFileBytes(for: metadata)
        let published = Calls()
        let written = try SSDBlockStore.writeStreaming(
            to: file, metadata: metadata, kekKey: SymmetricKey(size: .bits256), maximumChunkBytes: 4 << 20,
            beforePublish: { bytes in
                #expect(bytes == predicted)
                #expect(!FileManager.default.fileExists(atPath: file.path), "not yet under its final name")
                published.add()
            },
            chunk: { Data(repeating: UInt8(truncatingIfNeeded: $0), count: sizes[$0]) })
        #expect(published.count == 1)
        #expect(written == predicted)
        #expect(try fileBytes(file) == predicted)
        #expect(predicted == SSDBlockStore.streamedFixedBytes + (try SSDBlockStore.canonicalEncode(metadata).count)
            + sizes.reduce(0, +) + sizes.count * SSDBlockStore.streamedChunkFramingBytes)
    }

    @Test("a throw before publish leaves neither the file nor a temp file")
    func refusedPublishLeavesNothing() throws {
        struct Refused: Error {}
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ssd-refused-publish-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("0123456789ab")
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: model)
        let file = SSDBlockStore.fileURL(root: model, tag16Hex: String(repeating: "a", count: 32))
        let metadata = SSDBlockMetadata(
            lookupTag: String(repeating: "a", count: 64), weightHash: "weights", layoutEpoch: "stored-size",
            blockSize: 256, layerCount: 1,
            chunks: [.init(layerIndex: 0, tensor: 0, shape: [8], dtype: "uint8")],
            chunkPlaintextSizes: [8], createdAt: 1)
        #expect(throws: Refused.self) {
            _ = try SSDBlockStore.writeStreaming(
                to: file, metadata: metadata, kekKey: SymmetricKey(size: .bits256), maximumChunkBytes: 4096,
                beforePublish: { _ in throw Refused() }, chunk: { _ in Data(repeating: 1, count: 8) })
        }
        #expect(!exists(file))
        #expect(tempFiles(under: root).isEmpty)
    }

    @Test("a store's written bytes equal the stored size it reserved", arguments: [(256, false), (2048, false), (512, true)])
    func storeWritesWhatItReserved(position: Int, paged: Bool) async throws {
        let fixture = try SSDHybridCheckpointTestFixture(paged: paged, tokenCount: 2049)
        defer { fixture.remove() }
        let ledger = SSDDiskBudget()
        let store = try fixture.makeStore(diskBudget: ledger, maxWriteBytesPerDay: 0)
        defer { store.close() }
        let predicted = try storedBytes(fixture, store, position: position)
        #expect(try await donate(fixture, store, Self.firstSight, receipt: 20, position: position) == [position])
        #expect(store.stats().bytesWritten == predicted)
        #expect(try fileBytes(fixture.file(store, position: position)) == predicted)
        #expect(store.stats().maximumSegmentBytes > 0, "a finished write read its tensor segments")
        #expect(ledger.reservedBytesSnapshot == 0)
        #expect(ledger.totalBytes == predicted)
        await store.closeAndWait()
    }

    // MARK: A write in flight

    #if DEBUG
    /// Holds a store's writer once it holds its disk claim for `file` and
    /// before its first byte.
    private func holdAfterClaim(_ store: SSDHybridCheckpointStore, for file: URL) -> Support.Barrier {
        let barrier = Support.Barrier()
        store.afterDiskClaimForTesting = { url in
            guard url == file else { return }
            do { try barrier.block() } catch { Issue.record("writer barrier timed out: \(error)") }
        }
        return barrier
    }

    @Test("a first-sight write revoked for a proven write stops at its next chunk, leaves nothing on disk and keeps its write-budget charge")
    func revokedMidFlightYields() async throws {
        let cap = 1 << 30
        let a = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        let b = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { a.remove(); b.remove() }
        let ledger = SSDDiskBudget()
        let disk = DiskBudget()
        let outcomes = PrefixCacheDonationTelemetry()
        let first = try a.makeStore(diskBudget: ledger, maxWriteBytesPerDay: cap, diskBudgetBytes: { disk.bytes },
                                    donationRecorder: outcomes, writeNowSeconds: { 0 })
        let second = try b.makeStore(diskBudget: ledger, maxWriteBytesPerDay: 0, diskBudgetBytes: { disk.bytes })
        defer { first.close(); second.close() }
        let target = a.file(first, position: 256)
        let size = try storedBytes(a, first, position: 256)
        disk.bytes = size
        let held = holdAfterClaim(first, for: target)
        defer { held.release() }
        let speculative = Task { try await donate(a, first, Self.firstSight, receipt: 21, position: 256) }
        try await Support.waitUntil { held.isEntered }
        #expect(ledger.reservedBytesSnapshot == size)
        // The proven write takes the only room there is.
        #expect(try await donate(b, second, Self.coordinatorRepeat, receipt: 22, position: 256) == [256])
        held.release()
        #expect(try await speculative.value.isEmpty)
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(first.stats().speculativeWritesYielded == 1)
        #expect(first.stats().filesWritten == 0)
        #expect(first.stats().maximumSegmentBytes == 0, "stopped at the chunk check, before any tensor segment was read")
        #expect(!exists(target))
        #expect(tempFiles(under: a.root).isEmpty)
        #expect(ledger.reservedBytesSnapshot == 0)
        #expect(ledger.evictionCount == 0)
        #expect(exists(b.file(second, position: 256)))
        #expect(!first.rateLimiter.mightAccept(bytes: cap), "bytes were charged before the first chunk; no refund")
        #expect(first.lock.withLock { first.writing.isEmpty })
        await first.closeAndWait()
        await second.closeAndWait()
    }

    @Test("a first-sight write whose room is gone when its file is finished is never published")
    func roomGoneBeforePublish() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let ledger = SSDDiskBudget()
        let disk = DiskBudget()
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(diskBudget: ledger, maxWriteBytesPerDay: 0,
                                          diskBudgetBytes: { disk.bytes }, donationRecorder: outcomes)
        defer { store.close() }
        #expect(try await donate(fixture, store, Self.coordinatorRepeat, receipt: 23, position: 256) == [256])
        let existing = fixture.file(store, position: 256)
        try age(store, existing, by: 300)
        let target = fixture.file(store, position: 512)
        disk.bytes = store.stats().bytesOnDisk + (try storedBytes(fixture, store, position: 512))
        let published = Calls()
        store.lock.withLock { store.beforeWriteIndexForTesting = { url, _ in if url == target { published.add() } } }
        let held = holdAfterClaim(store, for: target)
        defer { held.release() }
        let speculative = Task { try await donate(fixture, store, Self.firstSight, receipt: 24, position: 512) }
        try await Support.waitUntil { held.isEntered }
        disk.bytes -= 1
        held.release()
        #expect(try await speculative.value.isEmpty)
        #expect(published.count == 0, "the file never appeared under its final name")
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(store.stats().speculativeWritesYielded == 1)
        #expect(store.stats().evictions == 0)
        #expect(exists(existing))
        #expect(!exists(target))
        #expect(tempFiles(under: fixture.root).isEmpty)
        #expect(ledger.reservedBytesSnapshot == 0)
        await store.closeAndWait()
    }

    @Test("a first-sight write revoked after its first chunks stops at the next one and leaves no temp file")
    func revokedBetweenChunksYields() async throws {
        let a = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        let b = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { a.remove(); b.remove() }
        let ledger = SSDDiskBudget()
        let disk = DiskBudget()
        let outcomes = PrefixCacheDonationTelemetry()
        let first = try a.makeStore(diskBudget: ledger, maxWriteBytesPerDay: 0, diskBudgetBytes: { disk.bytes },
                                    donationRecorder: outcomes)
        let second = try b.makeStore(diskBudget: ledger, maxWriteBytesPerDay: 0, diskBudgetBytes: { disk.bytes })
        defer { first.close(); second.close() }
        let target = a.file(first, position: 256)
        disk.bytes = try storedBytes(a, first, position: 256)
        // Hold the writer when it asks for its second chunk: the manifest
        // chunk is in the temp file by then.
        let held = Support.Barrier()
        defer { held.release() }
        let chunks = Calls()
        first.beforeSpeculativeChunkForTesting = { index in
            chunks.add()
            guard index == 1 else { return }
            do { try held.block() } catch { Issue.record("writer barrier timed out: \(error)") }
        }
        let speculative = Task { try await donate(a, first, Self.firstSight, receipt: 40, position: 256) }
        try await Support.waitUntil { held.isEntered }
        #expect(tempFiles(under: a.root).count == 1)
        #expect(try await donate(b, second, Self.coordinatorRepeat, receipt: 41, position: 256) == [256])
        held.release()
        #expect(try await speculative.value.isEmpty)
        #expect(chunks.count == 2, "it never asked for a third chunk")
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(first.stats().speculativeWritesYielded == 1)
        #expect(!exists(target))
        #expect(tempFiles(under: a.root).isEmpty)
        #expect(ledger.reservedBytesSnapshot == 0)
        #expect(ledger.evictionCount == 0)
        await first.closeAndWait()
        await second.closeAndWait()
    }

    @Test("a first-sight write whose store closes or whose epoch changes after it holds its room and before its file is finished publishes nothing and gives its room back",
          arguments: [true, false])
    func cancelledWhileHoldingRoom(close: Bool) async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let ledger = SSDDiskBudget()
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(diskBudget: ledger, maxWriteBytesPerDay: 0, donationRecorder: outcomes)
        defer { store.close() }
        let target = fixture.file(store, position: 256)
        let size = try storedBytes(fixture, store, position: 256)
        let published = Calls()
        store.lock.withLock { store.beforeWriteIndexForTesting = { url, _ in if url == target { published.add() } } }
        let held = holdAfterClaim(store, for: target)
        defer { held.release() }
        let speculative = Task { try await donate(fixture, store, Self.firstSight, receipt: 42, position: 256) }
        try await Support.waitUntil { held.isEntered }
        #expect(ledger.reservedBytesSnapshot == size)
        if close { store.close() } else { #expect(store.config.epochStore?.rotate() != nil) }
        held.release()
        #expect(try await speculative.value.isEmpty)
        await store.closeAndWait()
        #expect(count(outcomes, close ? .cacheClosed : .cacheEpochChanged) == 1)
        #expect(count(outcomes, .writeSpeculativeLimited) == 0)
        #expect(published.count == 0)
        #expect(!exists(target))
        #expect(tempFiles(under: fixture.root).isEmpty)
        #expect(ledger.reservedBytesSnapshot == 0)
        #expect(store.index.count == 0)
        // Only what the store had indexed when it closed is left on its
        // root: nothing of the cancelled write.
        #expect(ledger.unownedBytesSnapshot(wholeRootKey: SSDDiskBudget.rootKey(fixture.root)) == 0)
    }

    @Test("a first-sight file is not indexed into a store that closes or changes epoch between its last check and its commit; it is removed",
          arguments: [true, false])
    func closedAtCommit(close: Bool) async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let ledger = SSDDiskBudget()
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(diskBudget: ledger, maxWriteBytesPerDay: 0, donationRecorder: outcomes)
        defer { store.close() }
        let target = fixture.file(store, position: 256)
        // Runs after the closed and epoch guards and before the index insert.
        store.afterPublishBeforeIndexForTesting = {
            if close { store.close() } else { _ = store.config.epochStore?.rotate() }
        }
        #expect(try await donate(fixture, store, Self.firstSight, receipt: 43, position: 256).isEmpty)
        await store.closeAndWait()
        #expect(count(outcomes, close ? .cacheClosed : .cacheEpochChanged) == 1)
        #expect(store.index.count == 0)
        #expect(!exists(target))
        #expect(ledger.reservedBytesSnapshot == 0)
        #expect(ledger.unownedBytesSnapshot(wholeRootKey: SSDDiskBudget.rootKey(fixture.root)) == 0)
    }

    @Test("a first-sight write gives way to a proven write queued behind it in its own store when both do not fit")
    func provenQueuedBehindSpeculative() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let ledger = SSDDiskBudget()
        let disk = DiskBudget()
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(diskBudget: ledger, maxWriteBytesPerDay: 0,
                                          diskBudgetBytes: { disk.bytes }, donationRecorder: outcomes)
        defer { store.close() }
        #expect(try await donate(fixture, store, Self.coordinatorRepeat, receipt: 46, position: 256) == [256])
        let existing = fixture.file(store, position: 256)
        try age(store, existing, by: 300)
        let speculativeFile = fixture.file(store, position: 512)
        // Room for the first-sight file, and for nothing else.
        disk.bytes = store.stats().bytesOnDisk + (try storedBytes(fixture, store, position: 512))
        let held = holdAfterClaim(store, for: speculativeFile)
        defer { held.release() }
        let published = Calls()
        store.lock.withLock {
            store.beforeWriteIndexForTesting = { url, _ in if url == speculativeFile { published.add() } }
        }
        let speculative = Task { try await donate(fixture, store, Self.firstSight, receipt: 47, position: 512) }
        try await Support.waitUntil { held.isEntered }
        let queued = Task { try await donate(fixture, store, Self.coordinatorRepeat, receipt: 48, position: 768) }
        try await Support.waitUntil { store.lock.withLock { store.writing.count == 2 } }
        #expect(store.queuedWriteBytes > 0)
        held.release()
        #expect(try await speculative.value.isEmpty)
        #expect(try await queued.value == [768])
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(store.stats().speculativeWritesYielded == 1)
        #expect(published.count == 0, "it was stopped before its file was published")
        #expect(!exists(speculativeFile))
        // The proven write then evicts for itself, as it always has.
        #expect(store.stats().evictions == 1)
        #expect(!exists(existing))
        #expect(store.lock.withLock { store.provenWriteBytes.isEmpty })
        await store.closeAndWait()
    }
    @Test("a proven write that fits beside a first-sight write in flight in another store does not tell it to give way")
    func provenThatFitsRevokesNothing() async throws {
        let a = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        let b = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { a.remove(); b.remove() }
        let ledger = SSDDiskBudget()
        let disk = DiskBudget()
        let outcomes = PrefixCacheDonationTelemetry()
        let first = try a.makeStore(diskBudget: ledger, maxWriteBytesPerDay: 0, diskBudgetBytes: { disk.bytes },
                                    donationRecorder: outcomes)
        let second = try b.makeStore(diskBudget: ledger, maxWriteBytesPerDay: 0, diskBudgetBytes: { disk.bytes })
        defer { first.close(); second.close() }
        let target = a.file(first, position: 256)
        // Room for both files and not a byte more.
        disk.bytes = (try storedBytes(a, first, position: 256)) + (try storedBytes(b, second, position: 256))
        let held = holdAfterClaim(first, for: target)
        defer { held.release() }
        let speculative = Task { try await donate(a, first, Self.firstSight, receipt: 79, position: 256) }
        try await Support.waitUntil { held.isEntered }
        #expect(try await donate(b, second, Self.coordinatorRepeat, receipt: 80, position: 256) == [256])
        held.release()
        #expect(try await speculative.value == [256])
        #expect(first.stats().speculativeWritesYielded == 0)
        #expect(count(outcomes, .writeSpeculativeLimited) == 0)
        #expect(ledger.evictionCount == 0)
        #expect(ledger.reservedBytesSnapshot == 0)
        await first.closeAndWait()
        await second.closeAndWait()
    }

    @Test("a first-sight write whose room a proven write already queued in its store will take is declined before I/O")
    func provenQueuedBeforeSpeculativeReserves() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let ledger = SSDDiskBudget()
        let disk = DiskBudget()
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(diskBudget: ledger, maxWriteBytesPerDay: 0,
                                          diskBudgetBytes: { disk.bytes }, donationRecorder: outcomes)
        defer { store.close() }
        #expect(try await donate(fixture, store, Self.coordinatorRepeat, receipt: 70, position: 256) == [256])
        try age(store, fixture.file(store, position: 256), by: 300)
        let speculativeFile = fixture.file(store, position: 512)
        // Room for the first-sight file, and for nothing else.
        disk.bytes = store.stats().bytesOnDisk + (try storedBytes(fixture, store, position: 512))
        let chunks = Calls()
        store.beforeSpeculativeChunkForTesting = { _ in chunks.add() }
        // The first-sight job is accepted and waits for its file; the proven
        // job is accepted behind it before the writer reserves anything.
        let lease = try #require(store.fileCoordinator.tryAcquire(to: speculativeFile))
        defer { lease.release() }
        let speculative = Task { try await donate(fixture, store, Self.firstSight, receipt: 71, position: 512) }
        try await Support.waitUntil { store.fileCoordinator.pendingCount(for: speculativeFile) == 1 }
        let queued = Task { try await donate(fixture, store, Self.coordinatorRepeat, receipt: 72, position: 768) }
        try await Support.waitUntil { store.queuedWriteBytes > 0 }
        lease.release()
        #expect(try await speculative.value.isEmpty)
        #expect(try await queued.value == [768])
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(chunks.count == 0, "no byte was written for it")
        #expect(store.stats().speculativeWritesYielded == 0, "declined, not withdrawn")
        #expect(!exists(speculativeFile))
        #expect(tempFiles(under: fixture.root).isEmpty)
        #expect(store.queuedWriteBytes == 0)
        #expect(ledger.reservedBytesSnapshot == 0)
        await store.closeAndWait()
    }

    @Test("a request that re-offers a checkpoint already on disk writes nothing, so it takes no room from a first-sight write in flight")
    func durableDuplicateQueuesNoBytes() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let ledger = SSDDiskBudget()
        let disk = DiskBudget()
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(diskBudget: ledger, maxWriteBytesPerDay: 0,
                                          diskBudgetBytes: { disk.bytes }, donationRecorder: outcomes)
        defer { store.close() }
        #expect(try await donate(fixture, store, Self.coordinatorRepeat, receipt: 73, position: 256) == [256])
        let existing = fixture.file(store, position: 256)
        let speculativeFile = fixture.file(store, position: 512)
        disk.bytes = store.stats().bytesOnDisk + (try storedBytes(fixture, store, position: 512))
        let held = holdAfterClaim(store, for: speculativeFile)
        defer { held.release() }
        let speculative = Task { try await donate(fixture, store, Self.firstSight, receipt: 74, position: 512) }
        try await Support.waitUntil { held.isEntered }
        let duplicate = Task { try await donate(fixture, store, Self.coordinatorRepeat, receipt: 75, position: 256) }
        try await Support.waitUntil { store.lock.withLock { store.writing.count == 2 } }
        #expect(store.queuedWriteBytes == 0)
        held.release()
        #expect(try await speculative.value == [512])
        _ = try await duplicate.value
        #expect(store.stats().speculativeWritesYielded == 0)
        #expect(count(outcomes, .writeSpeculativeLimited) == 0)
        #expect(exists(speculativeFile))
        #expect(exists(existing))
        #expect(ledger.evictionCount == 0)
        await store.closeAndWait()
    }

    @Test("under a budget of half the free bytes, enforcement after a proven write in one store does not evict for the bytes a first-sight write in another store has on the volume")
    func enforceAfterAProvenWriteCreditsAnotherStoresFirstSightBytes() async throws {
        let a = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        let b = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { a.remove(); b.remove() }
        let ledger = SSDDiskBudget()
        let free = DiskBudget()
        let outcomes = PrefixCacheDonationTelemetry()
        let first = try a.makeStore(
            diskBudget: ledger, maxWriteBytesPerDay: 0, diskBudgetBytes: { max(1, free.bytes / 2) },
            donationRecorder: outcomes, diskBudgetBasis: { .halfOfFree(freeBytes: free.bytes) })
        let second = try b.makeStore(
            diskBudget: ledger, maxWriteBytesPerDay: 0, diskBudgetBytes: { max(1, free.bytes / 2) },
            diskBudgetBasis: { .halfOfFree(freeBytes: free.bytes) })
        defer { first.close(); second.close() }
        // The first-sight write has its first chunks on the volume.
        let held = Support.Barrier()
        defer { held.release() }
        first.beforeSpeculativeChunkForTesting = { index in
            guard index == 1 else { return }
            do { try held.block() } catch { Issue.record("writer barrier timed out: \(error)") }
        }
        let speculative = Task { try await donate(a, first, Self.firstSight, receipt: 76, position: 256) }
        try await Support.waitUntil { held.isEntered }
        // The volume as it reads with those bytes on it: half of it is one
        // byte short of the proven file. Without them the file fits.
        let provenFile = b.file(second, position: 256)
        free.bytes = 2 * (try storedBytes(b, second, position: 256)) - 2
        #expect(try await donate(b, second, Self.coordinatorRepeat, receipt: 77, position: 256) == [256])
        #expect(ledger.evictionCount == 0)
        #expect(exists(provenFile))
        held.release()
        #expect(try await speculative.value.isEmpty, "the proven write took the room")
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(tempFiles(under: a.root).isEmpty)
        #expect(ledger.reservedBytesSnapshot == 0)
        await first.closeAndWait()
        await second.closeAndWait()
    }
    #endif

    @Test("a proven file published as its store closes stays on disk, as before, and is counted as bytes no index owns")
    func provenAbandonedAfterPublishStaysAndCounts() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let ledger = SSDDiskBudget()
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(diskBudget: ledger, maxWriteBytesPerDay: 0, donationRecorder: outcomes)
        defer { store.close() }
        #expect(try await donate(fixture, store, Self.coordinatorRepeat, receipt: 44, position: 256) == [256])
        let entryBytes = store.stats().bytesOnDisk
        let target = fixture.file(store, position: 512)
        let size = try storedBytes(fixture, store, position: 512)
        let barrier = Support.Barrier()
        defer { barrier.release() }
        store.lock.withLock {
            store.beforeWriteIndexForTesting = { url, _ in
                guard url == target else { return }
                do { try barrier.block() } catch { Issue.record("writer barrier timed out: \(error)") }
            }
        }
        let proven = Task { try await donate(fixture, store, Self.coordinatorRepeat, receipt: 45, position: 512) }
        try await Support.waitUntil { barrier.isEntered }
        store.close()
        barrier.release()
        #expect(try await proven.value.isEmpty)
        await store.closeAndWait()
        #expect(count(outcomes, .cacheClosed) == 1)
        #expect(exists(target))
        #expect(store.index.count == 1)
        #expect(ledger.reservedBytesSnapshot == 0)
        #expect(ledger.unownedBytesSnapshot(wholeRootKey: SSDDiskBudget.rootKey(fixture.root)) == entryBytes + size)
    }

    // MARK: Refusals that spend nothing

    @Test("a first-sight offer declined at the stored-size margin is settled on the offering thread and spends no write budget, no I/O and no writer slot")
    func nearFullDeclineSpendsNothing() async throws {
        let cap = 1 << 30
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let ledger = SSDDiskBudget()
        let disk = DiskBudget()
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(diskBudget: ledger, maxWriteBytesPerDay: cap, diskBudgetBytes: { disk.bytes },
                                          donationRecorder: outcomes, writeNowSeconds: { 0 })
        defer { store.close() }
        #expect(try await donate(fixture, store, Self.coordinatorRepeat, receipt: 50, position: 256) == [256])
        let segmentBytes = store.stats().maximumSegmentBytes
        let plaintext = try SSDHybridCheckpointEnvelope(
            manifest: fixture.manifest(position: 256), maximumPlaintextBytes: 16 << 20).plaintextBytes
        disk.bytes = store.stats().bytesOnDisk + (try storedBytes(fixture, store, position: 512)) - 1
        // The file's lease is held: an offer that became a job would still
        // be waiting for it when `donate` returns.
        let target = fixture.file(store, position: 512)
        let lease = try #require(store.fileCoordinator.tryAcquire(to: target))
        defer { lease.release() }
        let settled = Calls()
        store.registerDonationDemand(Self.firstSight, requestID: .init(51))
        store.donate(try fixture.source(position: 512), requestID: .init(51), tokens: fixture.tokens,
                     cacheSalt: "tenant-a") { positions in if positions.isEmpty { settled.add() } }
        #expect(settled.count == 1, "declined before `donate` returned")
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(store.fileCoordinator.pendingCount(for: target) == 0)
        #expect(store.lock.withLock { store.writing.isEmpty })
        #expect(store.stats().speculativeWritesYielded == 0)
        #expect(store.stats().maximumSegmentBytes == segmentBytes)
        #expect(ledger.reservedBytesSnapshot == 0)
        // Only the proven write was charged.
        #expect(store.rateLimiter.mightAccept(bytes: cap - plaintext))
        #expect(!store.rateLimiter.mightAccept(bytes: cap - plaintext + 1))
        await store.closeAndWait()
    }

    @Test("a first-sight write granted disk room and then refused by the write budget gives the room back")
    func chargeRefusedAfterReservationReleases() async throws {
        let cap = 1 << 30
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let ledger = SSDDiskBudget()
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(diskBudget: ledger, maxWriteBytesPerDay: cap,
                                          donationRecorder: outcomes, writeNowSeconds: { 0 })
        defer { store.close() }
        let target = fixture.file(store, position: 256)
        let lease = try #require(store.fileCoordinator.tryAcquire(to: target))
        let offer = Task { try await donate(fixture, store, Self.firstSight, receipt: 52, position: 256) }
        try await Support.waitUntil { store.fileCoordinator.pendingCount(for: target) == 1 }
        // Write pressure arrives while the job waits for its file.
        #expect(store.rateLimiter.tryConsume(bytes: cap / 20))
        lease.release()
        #expect(try await offer.value.isEmpty)
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(store.stats().filesWritten == 0)
        #expect(store.stats().speculativeWritesYielded == 0)
        #expect(ledger.reservedBytesSnapshot == 0)
        #expect(tempFiles(under: fixture.root).isEmpty)
        await store.closeAndWait()
    }

    @Test("a first-sight write never replaces a file already at its path; a proven write still does")
    func speculativeNeverReplacesAFile() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let ledger = SSDDiskBudget()
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(diskBudget: ledger, maxWriteBytesPerDay: 0, donationRecorder: outcomes)
        defer { store.close() }
        // On disk and in no index of this store: left by a write that was
        // abandoned after publish, or indexed by a successor on this root.
        let target = fixture.file(store, position: 256)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let present = Data(repeating: 0x5a, count: 4096)
        try present.write(to: target)
        #expect(try await donate(fixture, store, Self.firstSight, receipt: 53, position: 256).isEmpty)
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(store.stats().filesWritten == 0)
        #expect(try Data(contentsOf: target) == present)
        #expect(ledger.reservedBytesSnapshot == 0)
        #expect(tempFiles(under: fixture.root).isEmpty)
        // The same checkpoint offered again is a local repeat, a proven
        // write, and replaces the file as before.
        #expect(try await donate(fixture, store, Self.firstSight, receipt: 54, position: 256) == [256])
        #expect(count(outcomes, .donated) == 1)
        #expect(try fileBytes(target) == (try storedBytes(fixture, store, position: 256)))
        await store.closeAndWait()
    }

    // MARK: Whole-root pass

    /// A store on its own ledger with the real whole-root pass on that
    /// ledger, run once at start as the factory does and after every write.
    private func storeWithWholeRootPass(
        _ fixture: SSDHybridCheckpointTestFixture, ledger: SSDDiskBudget, disk: DiskBudget,
        outcomes: PrefixCacheDonationTelemetry, evicted: Calls
    ) throws -> SSDHybridCheckpointStore {
        let root = fixture.root
        let maintain: @Sendable () -> Void = {
            let result = SSDWholeRootMaintainer().maintain(
                root: root, ttlSeconds: 3600, nowSeconds: Int64(Date().timeIntervalSince1970),
                budgetBytes: disk.bytes, budget: ledger)
            for _ in 0..<result.budgetEvicted { evicted.add() }
        }
        let store = try fixture.makeStore(
            epoch: false, diskBudget: ledger, maxWriteBytesPerDay: 0, diskBudgetBytes: { disk.bytes },
            donationRecorder: outcomes, maintainWholeRoot: maintain)
        maintain()
        return store
    }

    @Test("the whole-root pass does not evict a committed entry for a first-sight file that is published and not yet indexed; it tells that write to give way")
    func passSparesEntriesForAnInFlightSpeculativeFile() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let ledger = SSDDiskBudget()
        let disk = DiskBudget()
        let outcomes = PrefixCacheDonationTelemetry()
        let evicted = Calls()
        let store = try storeWithWholeRootPass(fixture, ledger: ledger, disk: disk, outcomes: outcomes, evicted: evicted)
        defer { store.close() }
        #expect(try await donate(fixture, store, Self.coordinatorRepeat, receipt: 25, position: 256) == [256])
        let existing = fixture.file(store, position: 256)
        try age(store, existing, by: 300)
        let entryBytes = store.stats().bytesOnDisk
        let target = fixture.file(store, position: 512)
        let size = try storedBytes(fixture, store, position: 512)
        disk.bytes = entryBytes + size
        let barrier = Support.Barrier()
        defer { barrier.release() }
        store.lock.withLock {
            store.beforeWriteIndexForTesting = { url, _ in
                guard url == target else { return }
                do { try barrier.block() } catch { Issue.record("writer barrier timed out: \(error)") }
            }
        }
        let speculative = Task { try await donate(fixture, store, Self.firstSight, receipt: 26, position: 512) }
        try await Support.waitUntil { barrier.isEntered }
        #expect(exists(target))
        // Another pass runs with one byte less than both files need.
        let result = SSDWholeRootMaintainer().maintain(
            root: fixture.root, ttlSeconds: 3600, nowSeconds: Int64(Date().timeIntervalSince1970),
            budgetBytes: entryBytes + size - 1, budget: ledger)
        #expect(result.budgetEvicted == 0)
        #expect(result.bytesAfter == entryBytes, "the in-flight file is not a committed entry")
        #expect(exists(existing))
        barrier.release()
        #expect(try await speculative.value.isEmpty, "the pass revoked it")
        #expect(store.stats().speculativeWritesYielded == 1)
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(!exists(target))
        #expect(exists(existing))
        #expect(evicted.count == 0)
        #expect(ledger.reservedBytesSnapshot == 0)
        await store.closeAndWait()
    }

    @Test("the whole-root pass keeps a speculative write's temp bytes out of its total and revokes the write; a temp file of no reservation still counts")
    func passDiscountsSpeculativeTempBytes() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let ledger = SSDDiskBudget()
        let store = try fixture.makeStore(epoch: false, diskBudget: ledger, maxWriteBytesPerDay: 0)
        defer { store.close() }
        #expect(try await donate(fixture, store, Self.coordinatorRepeat, receipt: 27, position: 256) == [256])
        let existing = fixture.file(store, position: 256)
        try age(store, existing, by: 300)
        let entryBytes = store.stats().bytesOnDisk
        // A write in flight for another checkpoint of this model: its temp
        // file is on disk and its room is reserved.
        let tagHex = String(repeating: "c", count: 32)
        let destination = SSDBlockStore.fileURL(root: fixture.modelRoot, tag16Hex: tagHex)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = SSDBlockStore.temporaryFileURL(for: destination)
        try Data(repeating: 9, count: 4096).write(to: temp)
        let reservation = try #require(ledger.reserveSpeculative(
            bytes: 4096, keys: [SSDDiskBudget.reservationKey(modelRootKey: SSDDiskBudget.rootKey(fixture.modelRoot), tag16Hex: tagHex)],
            wholeRootKey: SSDDiskBudget.rootKey(fixture.root), basis: .fixed(entryBytes + 4096)))
        let now = Int64(Date().timeIntervalSince1970)
        var result = SSDWholeRootMaintainer().maintain(
            root: fixture.root, ttlSeconds: 3600, nowSeconds: now, budgetBytes: entryBytes + 4095, budget: ledger)
        #expect(result.budgetEvicted == 0)
        #expect(exists(existing))
        #expect(reservation.isRevoked)
        #expect(ledger.unownedBytesSnapshot(wholeRootKey: SSDDiskBudget.rootKey(fixture.root)) == 0,
                "reserved temp bytes are counted once, as reserved")
        // The same temp file with no write behind it is plain disk usage.
        ledger.release(reservation, as: .discarded)
        result = SSDWholeRootMaintainer().maintain(
            root: fixture.root, ttlSeconds: 3600, nowSeconds: now, budgetBytes: entryBytes + 4095, budget: ledger)
        #expect(result.budgetEvicted == 1)
        #expect(!exists(existing))
        await store.closeAndWait()
    }

    @Test("under a budget of half the free bytes, the whole-root pass does not evict a committed entry because an in-flight first-sight write's bytes have lowered the limit")
    func passCreditsSpeculativeBytesUnderHalfOfFree() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let ledger = SSDDiskBudget()
        let store = try fixture.makeStore(epoch: false, diskBudget: ledger, maxWriteBytesPerDay: 0)
        defer { store.close() }
        #expect(try await donate(fixture, store, Self.coordinatorRepeat, receipt: 60, position: 256) == [256])
        let existing = fixture.file(store, position: 256)
        try age(store, existing, by: 300)
        let entryBytes = store.stats().bytesOnDisk
        let tagHex = String(repeating: "c", count: 32)
        let destination = SSDBlockStore.fileURL(root: fixture.modelRoot, tag16Hex: tagHex)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = SSDBlockStore.temporaryFileURL(for: destination)
        try Data(repeating: 9, count: 4096).write(to: temp)
        let reservation = try #require(ledger.reserveSpeculative(
            bytes: 4096, keys: [SSDDiskBudget.reservationKey(modelRootKey: SSDDiskBudget.rootKey(fixture.modelRoot), tag16Hex: tagHex)],
            wholeRootKey: SSDDiskBudget.rootKey(fixture.root), basis: .fixed(1 << 30)))
        // Free space as the volume reports it with the 4,096 temp bytes on
        // it: half of it is one byte short of the entry. Without those
        // bytes on the volume the entry fits with room to spare.
        let basis = SSDDiskBudgetBasis.halfOfFree(freeBytes: 2 * entryBytes - 2)
        let now = Int64(Date().timeIntervalSince1970)
        var result = SSDWholeRootMaintainer().maintain(
            root: fixture.root, ttlSeconds: 3600, nowSeconds: now, budgetBytes: basis.bytes(), budget: ledger,
            budgetBasis: basis)
        #expect(result.budgetEvicted == 0)
        #expect(exists(existing))
        #expect(reservation.isRevoked, "the root was over its limit with the write's bytes counted")
        // With no write behind the temp file the same pass evicts, as before.
        ledger.release(reservation, as: .discarded)
        result = SSDWholeRootMaintainer().maintain(
            root: fixture.root, ttlSeconds: 3600, nowSeconds: now, budgetBytes: basis.bytes(), budget: ledger,
            budgetBasis: basis)
        #expect(result.budgetEvicted == 1)
        #expect(!exists(existing))
        await store.closeAndWait()
    }

    /// A committed entry of `entryBytes`, aged, and a first-sight write in
    /// flight for another checkpoint of the same model with 4,096 bytes in
    /// its temp file.
    private func entryBesideAnInFlightTempFile(
        _ fixture: SSDHybridCheckpointTestFixture, _ store: SSDHybridCheckpointStore, ledger: SSDDiskBudget,
        receipt: UInt64
    ) async throws -> (existing: URL, entryBytes: Int, reservation: SSDDiskReservation) {
        #expect(try await donate(fixture, store, Self.coordinatorRepeat, receipt: receipt, position: 256) == [256])
        let existing = fixture.file(store, position: 256)
        try age(store, existing, by: 300)
        let entryBytes = store.stats().bytesOnDisk
        let tagHex = String(repeating: "c", count: 32)
        let destination = SSDBlockStore.fileURL(root: fixture.modelRoot, tag16Hex: tagHex)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 9, count: 4096).write(to: SSDBlockStore.temporaryFileURL(for: destination))
        let reservation = try #require(ledger.reserveSpeculative(
            bytes: 4096, keys: [SSDDiskBudget.reservationKey(modelRootKey: SSDDiskBudget.rootKey(fixture.modelRoot), tag16Hex: tagHex)],
            wholeRootKey: SSDDiskBudget.rootKey(fixture.root), basis: .fixed(1 << 30)))
        return (existing, entryBytes, reservation)
    }

    @Test("the whole-root pass still evicts for committed bytes that are over the budget on their own while a first-sight write is in flight",
          arguments: [false, true])
    func passStillEvictsForCommittedBytes(halfOfFree: Bool) async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let ledger = SSDDiskBudget()
        let store = try fixture.makeStore(epoch: false, diskBudget: ledger, maxWriteBytesPerDay: 0)
        defer { store.close() }
        let (existing, entryBytes, reservation) = try await entryBesideAnInFlightTempFile(
            fixture, store, ledger: ledger, receipt: 65)
        // One byte short of the entry, also once the write's 4,096 bytes
        // are credited to a half-of-free limit: (2E - 4100 + 4096) / 2.
        let basis: SSDDiskBudgetBasis = halfOfFree
            ? .halfOfFree(freeBytes: 2 * entryBytes - 4100) : .fixed(entryBytes - 1)
        let result = SSDWholeRootMaintainer().maintain(
            root: fixture.root, ttlSeconds: 3600, nowSeconds: Int64(Date().timeIntervalSince1970),
            budgetBytes: basis.bytes(), budget: ledger, budgetBasis: basis)
        #expect(result.budgetEvicted == 1, "the credit for the write in flight is its own bytes and no more")
        #expect(!exists(existing))
        #expect(reservation.isRevoked)
        ledger.release(reservation, as: .discarded)
        await store.closeAndWait()
    }

    @Test("a whole-root pass over a root that is exactly full with an in-flight first-sight file leaves the write alone")
    func passAtExactFitDoesNotRevoke() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let ledger = SSDDiskBudget()
        let disk = DiskBudget()
        let outcomes = PrefixCacheDonationTelemetry()
        let evicted = Calls()
        let store = try storeWithWholeRootPass(fixture, ledger: ledger, disk: disk, outcomes: outcomes, evicted: evicted)
        defer { store.close() }
        #expect(try await donate(fixture, store, Self.coordinatorRepeat, receipt: 66, position: 256) == [256])
        let existing = fixture.file(store, position: 256)
        try age(store, existing, by: 300)
        let entryBytes = store.stats().bytesOnDisk
        let target = fixture.file(store, position: 512)
        let size = try storedBytes(fixture, store, position: 512)
        disk.bytes = entryBytes + size
        let barrier = Support.Barrier()
        defer { barrier.release() }
        store.lock.withLock {
            store.beforeWriteIndexForTesting = { url, _ in
                guard url == target else { return }
                do { try barrier.block() } catch { Issue.record("writer barrier timed out: \(error)") }
            }
        }
        let speculative = Task { try await donate(fixture, store, Self.firstSight, receipt: 67, position: 512) }
        try await Support.waitUntil { barrier.isEntered }
        let result = SSDWholeRootMaintainer().maintain(
            root: fixture.root, ttlSeconds: 3600, nowSeconds: Int64(Date().timeIntervalSince1970),
            budgetBytes: entryBytes + size, budget: ledger)
        #expect(result.budgetEvicted == 0)
        barrier.release()
        #expect(try await speculative.value == [512], "both files fit: nothing told it to give way")
        #expect(store.stats().speculativeWritesYielded == 0)
        #expect(exists(target))
        #expect(exists(existing))
        #expect(evicted.count == 0)
        await store.closeAndWait()
    }

    @Test("a pass that cannot list a model's directory does not lower the bytes a first-sight checkpoint is held to")
    func passThatCannotListADirectoryRaisesOnly() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let unloadedRoot = fixture.root.appendingPathComponent("111111111111", isDirectory: true)
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: fixture.root, modelRoot: unloadedRoot)
        let unloaded = SSDBlockStore.fileURL(root: unloadedRoot, tag16Hex: String(repeating: "1", count: 32))
        let chunk = Data(repeating: 7, count: 4096)
        try SSDBlockStore.write(
            to: unloaded,
            metadata: SSDBlockMetadata(
                lookupTag: String(repeating: "ab", count: 32), weightHash: "weight", layoutEpoch: "layout",
                blockSize: 8, layerCount: 1,
                chunks: [.init(layerIndex: 0, tensor: 0, shape: [1, 1, 1, 1], dtype: "float16")],
                chunkPlaintextSizes: [chunk.count], createdAt: 1),
            chunks: [chunk], kekKey: SymmetricKey(size: .bits256))
        let unloadedBytes = try fileBytes(unloaded)
        let ledger = SSDDiskBudget()
        let key = SSDDiskBudget.rootKey(fixture.root)
        func pass() -> SSDWholeRootMaintainer.Result {
            SSDWholeRootMaintainer().maintain(
                root: fixture.root, ttlSeconds: 3600, nowSeconds: Int64(Date().timeIntervalSince1970),
                budgetBytes: 1 << 30, budget: ledger)
        }
        _ = pass()
        #expect(ledger.unownedBytesSnapshot(wholeRootKey: key) == unloadedBytes)
        // The directory cannot be listed: the walk finds none of its bytes.
        let fanout = unloaded.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fanout.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fanout.path) }
        try #require((try? FileManager.default.contentsOfDirectory(atPath: fanout.path)) == nil)
        _ = pass()
        #expect(ledger.unownedBytesSnapshot(wholeRootKey: key) == unloadedBytes, "it still counts")
        // Readable again and empty: a whole pass lowers the figure.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fanout.path)
        try FileManager.default.removeItem(at: unloaded)
        _ = pass()
        #expect(ledger.unownedBytesSnapshot(wholeRootKey: key) == 0)
    }

    @Test("the pass every production caller runs resolves its budget inside the pass, as half of the free bytes of the volume it is given")
    func productionPassResolvesItsBudgetInsideThePass() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let ledger = SSDDiskBudget()
        let store = try fixture.makeStore(epoch: false, diskBudget: ledger, maxWriteBytesPerDay: 0)
        defer { store.close() }
        let (existing, entryBytes, reservation) = try await entryBesideAnInFlightTempFile(
            fixture, store, ledger: ledger, receipt: 68)
        // The volume as it reads with the write's 4,096 bytes on it: half
        // of it is one byte short of the entry.
        let free = 2 * entryBytes - 2
        let probe = fixture.modelRoot
        let probed = Calls()
        let root = fixture.root
        func pass() -> SSDWholeRootMaintainer.Result {
            SSDPrefixCacheFactory.maintainWholeRoot(
                root: root, environment: [:], volumeProbe: probe,
                maintainer: SSDWholeRootMaintainer(), budget: ledger,
                freeBytes: { url in
                    if url == probe { probed.add() }
                    return free
                })
        }
        var result = pass()
        #expect(probed.count == 1)
        #expect(result.budgetEvicted == 0, "half of free, credited with the bytes of the write in flight")
        #expect(exists(existing))
        #expect(reservation.isRevoked)
        // With no write behind the temp file the same pass evicts.
        ledger.release(reservation, as: .discarded)
        result = pass()
        #expect(result.budgetEvicted == 1)
        #expect(!exists(existing))
        await store.closeAndWait()
    }

    @Test("a pass does not evict for the bytes of a first-sight write that was on the volume when the pass read it and is gone before the walk")
    func passCreditsAWriteWithdrawnInItsWindow() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let ledger = SSDDiskBudget()
        let store = try fixture.makeStore(epoch: false, diskBudget: ledger, maxWriteBytesPerDay: 0)
        defer { store.close() }
        #expect(try await donate(fixture, store, Self.coordinatorRepeat, receipt: 69, position: 256) == [256])
        let existing = fixture.file(store, position: 256)
        try age(store, existing, by: 300)
        let entryBytes = store.stats().bytesOnDisk
        let root = fixture.root
        let rootKey = SSDDiskBudget.rootKey(root)
        func pass(withdrawing: Bool) -> SSDWholeRootMaintainer.Result {
            SSDPrefixCacheFactory.maintainWholeRoot(
                root: root, environment: [:], maintainer: SSDWholeRootMaintainer(), budget: ledger,
                freeBytes: { _ in
                    // 4,096 bytes of a first-sight write are on the volume
                    // as it is read; the write is withdrawn before the walk.
                    if withdrawing, let passing = ledger.reserveSpeculative(
                        bytes: 4096, keys: ["withdrawn"], wholeRootKey: rootKey, basis: .fixed(1 << 30)) {
                        passing.noteLanded(upTo: 4096)
                        ledger.release(passing, as: .discarded)
                    }
                    // Half of it is one byte short of the entry.
                    return 2 * entryBytes - 2
                })
        }
        #expect(pass(withdrawing: true).budgetEvicted == 0)
        #expect(exists(existing))
        // The same reading with no such write behind it evicts, as before.
        #expect(pass(withdrawing: false).budgetEvicted == 1)
        #expect(!exists(existing))
        await store.closeAndWait()
    }

    @Test("the periodic pass evicts against the basis it was started with")
    func periodicPassUsesItsBasis() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let ledger = SSDDiskBudget()
        let store = try fixture.makeStore(epoch: false, diskBudget: ledger, maxWriteBytesPerDay: 0)
        defer { store.close() }
        let (existing, entryBytes, reservation) = try await entryBesideAnInFlightTempFile(
            fixture, store, ledger: ledger, receipt: 78)
        // Half of free, read with the write's 4,096 bytes on the volume,
        // is one byte short of the entry.
        let basis = SSDDiskBudgetBasis.halfOfFree(freeBytes: 2 * entryBytes - 2)
        let maintainer = SSDWholeRootMaintainer()
        maintainer.startPeriodicMaintenance(
            root: fixture.root, ttlSeconds: 3600, intervalSeconds: 3600,
            nowSeconds: { Int64(Date().timeIntervalSince1970) }, budgetBytes: { basis.bytes() },
            budgetBasis: { basis }, budget: ledger)
        defer { maintainer.stopPeriodicMaintenance(root: fixture.root) }
        try await Support.waitUntil { reservation.isRevoked }
        // A second pass waits for the first to finish.
        _ = maintainer.maintain(
            root: fixture.root, ttlSeconds: 3600, nowSeconds: Int64(Date().timeIntervalSince1970),
            budgetBytes: 1 << 30, budget: ledger)
        #expect(maintainer.statsSnapshot().budgetEvicted == 0)
        #expect(exists(existing))
        ledger.release(reservation, as: .discarded)
        await store.closeAndWait()
    }

    @Test("two live model stores under one cache root, with the real pass after every write, share room for one first-sight file without evicting")
    func twoLiveStoresUnderOneRoot() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let ledger = SSDDiskBudget()
        let disk = DiskBudget()
        let outcomesA = PrefixCacheDonationTelemetry()
        let outcomesB = PrefixCacheDonationTelemetry()
        let evicted = Calls()
        let a = try storeWithWholeRootPass(fixture, ledger: ledger, disk: disk, outcomes: outcomesA, evicted: evicted)
        defer { a.close() }
        let root = fixture.root
        let otherRoot = root.appendingPathComponent("abcdef012345", isDirectory: true)
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: otherRoot)
        let b = SSDHybridCheckpointStore(config: .init(
            modelId: "other-model", identity: fixture.identity, backendLayout: fixture.backendLayout,
            root: otherRoot, dedicatedRoot: root, epochStore: nil, maxReadBytes: 16 << 20,
            maxStageMillis: 1000, minEffectiveTokens: 256, ttlSeconds: 3600, strictFsync: false,
            nowSeconds: { Int64(Date().timeIntervalSince1970) }, diskBudgetBytes: { disk.bytes },
            maintainWholeRoot: {
                let result = SSDWholeRootMaintainer().maintain(
                    root: root, ttlSeconds: 3600, nowSeconds: Int64(Date().timeIntervalSince1970),
                    budgetBytes: disk.bytes, budget: ledger)
                for _ in 0..<result.budgetEvicted { evicted.add() }
            }),
            kekKey: fixture.key, kvBudget: fixture.budget, diskBudget: ledger, maxWriteBytesPerDay: 0,
            donationRecorder: outcomesB)
        b.scanOnDisk()
        defer { b.close() }
        #expect(try await donate(fixture, a, Self.coordinatorRepeat, receipt: 61, position: 512) == [512])
        #expect(try await donate(fixture, b, Self.coordinatorRepeat, receipt: 62, position: 512) == [512])
        try age(a, fixture.file(a, position: 512), by: 300)
        let size = try storedBytes(fixture, a, position: 256)
        disk.bytes = ledger.totalBytes + size
        #expect(ledger.unownedBytesSnapshot(wholeRootKey: SSDDiskBudget.rootKey(root)) == 0)
        let target = fixture.file(a, position: 256)
        let barrier = Support.Barrier()
        defer { barrier.release() }
        a.lock.withLock {
            a.beforeWriteIndexForTesting = { url, _ in
                guard url == target else { return }
                do { try barrier.block() } catch { Issue.record("writer barrier timed out: \(error)") }
            }
        }
        let first = Task { try await donate(fixture, a, Self.firstSight, receipt: 63, position: 256) }
        try await Support.waitUntil { barrier.isEntered }
        #expect(try await donate(fixture, b, Self.firstSight, receipt: 64, position: 256).isEmpty)
        #expect(count(outcomesB, .writeSpeculativeLimited) == 1)
        barrier.release()
        #expect(try await first.value == [256])
        #expect(evicted.count == 0)
        #expect(ledger.evictionCount == 0)
        #expect(ledger.totalBytes == disk.bytes)
        #expect(ledger.unownedBytesSnapshot(wholeRootKey: SSDDiskBudget.rootKey(root)) == 0)
        #expect(ledger.reservedBytesSnapshot == 0)
        await a.closeAndWait()
        await b.closeAndWait()
    }

    @Test("with the bytes of an unloaded model on disk, a first-sight checkpoint is written when everything fits exactly")
    func unloadedModelBytesExactFit() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let unloadedRoot = fixture.root.appendingPathComponent("111111111111", isDirectory: true)
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: fixture.root, modelRoot: unloadedRoot)
        let unloaded = SSDBlockStore.fileURL(root: unloadedRoot, tag16Hex: String(repeating: "1", count: 32))
        let chunk = Data(repeating: 7, count: 4096)
        try SSDBlockStore.write(
            to: unloaded,
            metadata: SSDBlockMetadata(
                lookupTag: String(repeating: "ab", count: 32), weightHash: "weight", layoutEpoch: "layout",
                blockSize: 8, layerCount: 1,
                chunks: [.init(layerIndex: 0, tensor: 0, shape: [1, 1, 1, 1], dtype: "float16")],
                chunkPlaintextSizes: [chunk.count], createdAt: 1),
            chunks: [chunk], kekKey: SymmetricKey(size: .bits256))
        let unloadedBytes = try fileBytes(unloaded)
        let ledger = SSDDiskBudget()
        let disk = DiskBudget()
        let outcomes = PrefixCacheDonationTelemetry()
        let evicted = Calls()
        let store = try storeWithWholeRootPass(fixture, ledger: ledger, disk: disk, outcomes: outcomes, evicted: evicted)
        defer { store.close() }
        #expect(ledger.unownedBytesSnapshot(wholeRootKey: SSDDiskBudget.rootKey(fixture.root)) == unloadedBytes)
        #expect(try await donate(fixture, store, Self.coordinatorRepeat, receipt: 28, position: 256) == [256])
        let size = try storedBytes(fixture, store, position: 512)
        disk.bytes = store.stats().bytesOnDisk + unloadedBytes + size
        #expect(try await donate(fixture, store, Self.firstSight, receipt: 29, position: 512) == [512])
        #expect(evicted.count == 0)
        #expect(store.stats().evictions == 0)
        #expect(exists(unloaded))
        #expect(ledger.unownedBytesSnapshot(wholeRootKey: SSDDiskBudget.rootKey(fixture.root)) == unloadedBytes)
        await store.closeAndWait()
    }

    @Test("a model store that closes leaves its files in the occupancy another store's first-sight checkpoint is held to")
    func closedStoreBytesStillCount() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let ledger = SSDDiskBudget()
        let disk = DiskBudget()
        let closing = try fixture.makeStore(diskBudget: ledger, maxWriteBytesPerDay: 0, diskBudgetBytes: { disk.bytes })
        #expect(try await donate(fixture, closing, Self.coordinatorRepeat, receipt: 30, position: 512) == [512])
        let closedBytes = closing.stats().bytesOnDisk
        await closing.closeAndWait()
        #expect(ledger.totalBytes == 0)
        #expect(ledger.unownedBytesSnapshot(wholeRootKey: SSDDiskBudget.rootKey(fixture.root)) == closedBytes)

        // A second model under the same cache root, as in production.
        let otherRoot = fixture.root.appendingPathComponent("abcdef012345", isDirectory: true)
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: fixture.root, modelRoot: otherRoot)
        let outcomes = PrefixCacheDonationTelemetry()
        let other = SSDHybridCheckpointStore(config: .init(
            modelId: "other-model", identity: fixture.identity, backendLayout: fixture.backendLayout,
            root: otherRoot, dedicatedRoot: fixture.root, epochStore: nil, maxReadBytes: 16 << 20,
            maxStageMillis: 1000, minEffectiveTokens: 256, ttlSeconds: 3600, strictFsync: false,
            nowSeconds: { Int64(Date().timeIntervalSince1970) }, diskBudgetBytes: { disk.bytes },
            maintainWholeRoot: {}),
            kekKey: fixture.key, kvBudget: fixture.budget, diskBudget: ledger, maxWriteBytesPerDay: 0,
            donationRecorder: outcomes)
        other.scanOnDisk()
        defer { other.close() }
        let size = try storedBytes(fixture, other, position: 256)
        disk.bytes = closedBytes + size - 1
        #expect(try await donate(fixture, other, Self.firstSight, receipt: 31, position: 256).isEmpty)
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(other.stats().filesWritten == 0)
        // A proven write is not held to it.
        #expect(try await donate(fixture, other, Self.coordinatorRepeat, receipt: 32, position: 768) == [768])
        await other.closeAndWait()
    }

    @Test("with a budget of half the free bytes, a store declines a first-sight checkpoint that fits the budget now and not the budget its bytes leave")
    func storeHoldsFirstSightToTheBudgetItsBytesLeave() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 2049)
        defer { fixture.remove() }
        let free = DiskBudget()
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(
            maxWriteBytesPerDay: 0, diskBudgetBytes: { max(1, free.bytes / 2) }, donationRecorder: outcomes,
            diskBudgetBasis: { .halfOfFree(freeBytes: free.bytes) })
        defer { store.close() }
        #expect(try await donate(fixture, store, Self.coordinatorRepeat, receipt: 33, position: 256) == [256])
        let existing = fixture.file(store, position: 256)
        try age(store, existing, by: 300)
        let entryBytes = store.stats().bytesOnDisk
        let size = try storedBytes(fixture, store, position: 512)
        // Half of free holds both files now; after the write it would not.
        free.bytes = 2 * (entryBytes + size) + size - 2
        #expect(try await donate(fixture, store, Self.firstSight, receipt: 34, position: 512).isEmpty)
        #expect(count(outcomes, .writeSpeculativeLimited) == 1)
        #expect(store.stats().filesWritten == 1)
        #expect(exists(existing))
        await store.closeAndWait()
    }
}
