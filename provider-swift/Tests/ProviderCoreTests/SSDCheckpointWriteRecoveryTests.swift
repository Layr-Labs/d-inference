import Foundation
import MLX
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Checkpoint write failure recovery", .serialized)
struct SSDCheckpointWriteRecoveryTests {
    @Test("a failed new file preserves existing cache evidence and a later donation recovers")
    func newFileFailurePreservesEpoch() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let telemetry = PrefixCacheDonationTelemetry()
        let store = try f.makeStore(donationRecorder: telemetry)
        #expect(try await f.donate(store) == [256])
        let epoch = store.config.epochStore?.current
        let blocked = f.file(store, position: 512)
        // A directory at the new target must be rejected by no-follow I/O.
        // The existing 256-token checkpoint is a different, valid file.
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        #expect(try await f.donate(store, receipt: 11, position: 512).isEmpty)
        #expect(store.config.epochStore?.current == epoch)
        #expect(store.index.count == 1)
        #expect(store.stats().corruptDropped == 0)
        #expect(count(.writeIOFailed, in: telemetry) == 1)
        let stage = await store.stage(requestID: .init(70), request: f.request(),
                                      reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(stage.staged)
        #expect(stage.stagedTokens == 256)
        await store.abandonStaging(requestID: .init(70))

        // Clear only the fixture obstruction; retry with a fresh donation.
        try FileManager.default.removeItem(at: blocked)
        #expect(try await f.donate(store, receipt: 12, position: 512) == [512])
        #expect(store.config.epochStore?.current == epoch)
        #expect(store.index.count == 2)
        #expect(count(.donated, in: telemetry) == 2)
        #expect(telemetry.snapshot().reduce(0) { $0 + $1.count } == 3)
        await store.closeAndWait()
    }

    @Test("unreadable existing data still revokes its epoch and publishes no receipt")
    func existingFileFailureRevokesEpoch() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let telemetry = PrefixCacheDonationTelemetry()
        let store = try f.makeStore(donationRecorder: telemetry)
        #expect(try await f.donate(store) == [256])
        let epoch = store.config.epochStore?.current
        try Data([0, 1, 2]).write(to: f.file(store))
        #expect(try await f.donate(store, receipt: 11).isEmpty)
        #expect(store.config.epochStore?.current != epoch)
        #expect(store.index.count == 0)
        #expect(count(.existingCacheUnreadable, in: telemetry) == 1)
        #expect(store.stats().corruptDropped == 1)
        await store.closeAndWait()
    }

    @Test("maintenance refusal is distinguished and does not poison a later donation")
    func maintenanceRefusalCanRecover() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let telemetry = PrefixCacheDonationTelemetry()
        let store = try f.makeStore(donationRecorder: telemetry)
        store.lock.withLock { store.destructiveChange = true }
        #expect(try await f.donate(store).isEmpty)
        #expect(count(.cacheMaintenanceBusy, in: telemetry) == 1)
        store.lock.withLock { store.destructiveChange = false }
        #expect(try await f.donate(store, receipt: 11) == [256])
        #expect(count(.donated, in: telemetry) == 1)
        await store.closeAndWait()
    }

    @Test("missing host reservation authority is not a disk write failure")
    func hostReservationRefusal() async throws {
        let f = try SSDHybridCheckpointTestFixture(sharedPaged: true)
        defer { f.remove() }
        let telemetry = PrefixCacheDonationTelemetry()
        let store = try f.makeStore(useGlobalBudget: false, donationRecorder: telemetry)
        #expect(try await f.donate(store).isEmpty)
        #expect(count(.hostMemoryUnavailable, in: telemetry) == 1)
        #expect(count(.writeFailed, in: telemetry) == 0)
        #expect(store.stats().filesWritten == 0)
        await store.closeAndWait()
    }

    @Test("failure classification never depends on error descriptions")
    func boundedErrorClassification() {
        #expect(SSDHybridCheckpointStore.freshWriteFailureOutcome(
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))) == .diskSpaceInsufficient)
        #expect(SSDHybridCheckpointStore.freshWriteFailureOutcome(
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)) == .diskSpaceInsufficient)
        #expect(SSDHybridCheckpointStore.freshWriteFailureOutcome(
            SSDBlockStoreError.ioFailure("private path or error text")) == .writeIOFailed)
        #expect(SSDHybridCheckpointStore.freshWriteFailureOutcome(
            CBv2CompleteCheckpointError.invalidManifest) == .writeFailed)
    }

    @Test("atomic-write POSIX wrappers retain disk-full errno after cleanup changes it")
    func wrappedDiskFullClassification() {
        let previousErrno = errno
        defer { errno = previousErrno }
        // Construct the path before simulating the syscall failure: Foundation
        // URL initialization itself can change errno, unlike the existing URL
        // variables passed by the production openat/renameat call sites.
        let url = URL(fileURLWithPath: "/private/cache/test.dbk3")
        for operation in ["openat temp", "renameat"] {
            for code in [Int32(ENOSPC), Int32(EIO)] {
                errno = code
                let wrapped = SSDNoFollowIO.posixError(operation, url: url)
                errno = EINVAL
                #expect(SSDHybridCheckpointStore.freshWriteFailureOutcome(wrapped)
                    == (code == ENOSPC ? .diskSpaceInsufficient : .writeIOFailed))
            }
        }
    }

    @Test("evicting the written endpoint reports eviction before its epoch change")
    func donationEvictedByBudget() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let telemetry = PrefixCacheDonationTelemetry()
        let store = try f.makeStore(diskBudgetBytes: { 0 }, donationRecorder: telemetry)
        let epoch = store.config.epochStore?.current
        #expect(try await f.donate(store).isEmpty)
        #expect(store.stats().filesWritten == 1)
        #expect(store.stats().evictions == 1)
        #expect(store.index.count == 0)
        #expect(store.config.epochStore?.current != epoch)
        #expect(count(.cacheEntryEvicted, in: telemetry) == 1)
        #expect(count(.cacheEpochChanged, in: telemetry) == 0)
        #expect(telemetry.snapshot().reduce(0) { $0 + $1.count } == 1)
        await store.closeAndWait()
    }

    private func count(_ outcome: PrefixCacheDonationOutcome, in telemetry: PrefixCacheDonationTelemetry) -> UInt64 {
        telemetry.snapshot().first { $0.outcome == outcome }?.count ?? 0
    }
}
