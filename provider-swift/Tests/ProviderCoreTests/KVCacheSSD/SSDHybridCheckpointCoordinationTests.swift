import Foundation
import MLX
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Complete checkpoint coordinated staging", .serialized)
struct SSDHybridCheckpointCoordinationTests {
    /// The bytes a read observed while another stage ran, set once.
    private final class Observation: @unchecked Sendable {
        private let lock = NSLock()
        private var observed: Int?
        var value: Int? { lock.withLock { observed } }
        func record(_ value: Int) { lock.withLock { observed = observed ?? value } }
    }

    private static func modified(_ file: URL) throws -> Date {
        try #require(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
    }

    @Test("same-file stages overlap; only a reader left alone refreshes recency, and receipts it outdated reauthenticate",
          arguments: [false, true])
    func overlappingStages(sharedPaged: Bool) async throws {
        let fixture = try SSDHybridCheckpointTestFixture(sharedPaged: sharedPaged)
        defer { fixture.remove() }
        defer { fixture.codec.admission.closeProcessMemoryOwner() }
        let store = try fixture.makeStore()
        defer { store.close() }
        #expect(try await fixture.donate(store) == [256])
        let file = fixture.file(store)
        let original = try Data(contentsOf: file)
        let epoch = store.config.epochStore?.current
        // Old enough that a hit refreshes the persisted recency.
        let stale = Date(timeIntervalSince1970: Double(store.config.nowSeconds() - 2 * store.recencyRefreshSeconds))
        SSDBlockStore.setAttributesIfSafe([.modificationDate: stale], at: file, under: fixture.modelRoot)
        let firstPlan = SSDCheckpointCoordinationTestSupport.Barrier()
        let secondPlan = SSDCheckpointCoordinationTestSupport.Barrier()
        defer { firstPlan.release(); secondPlan.release() }
        let first = Task.detached {
            await store.stage(requestID: .init(101), request: fixture.request(), reserveReadScratch: fixture.reserveReadScratch) { manifest in
                try firstPlan.block()
                return try fixture.plan(manifest)
            }
        }
        defer { first.cancel(); firstPlan.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { firstPlan.isEntered }
        let second = Task.detached {
            await store.stage(requestID: .init(102), request: fixture.request(), reserveReadScratch: fixture.reserveReadScratch) { manifest in
                try secondPlan.block()
                return try fixture.plan(manifest)
            }
        }
        defer { second.cancel(); secondPlan.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { secondPlan.isEntered }
        // Both stages are inside the same file; neither waits for the other.
        #expect(store.fileCoordinator.pendingCount(for: file) == 0)
        #expect(store.stats().filesRead == 2)
        #expect(store.stats().stagedBytesInUse == 2 * SSDHybridCheckpointStore.ioScratchBytes)
        secondPlan.release()
        #expect(await second.value.staged)
        #expect(store.stats().filesRead == 3)
        #expect(try Self.modified(file) == stale, "a reader never touches a file another reader holds")
        firstPlan.release()
        #expect(await first.value.staged)
        #expect(store.stats().filesRead == 4)
        #expect(try Self.modified(file) > stale, "the reader left alone refreshes recency")
        // 101 recorded its file identity after its own touch; 102's predates it.
        #expect(try await fixture.donate(store, receipt: 101) == [256])
        #expect(store.stats().donationReadBytes == 0)
        #expect(try await fixture.donate(store, receipt: 102) == [256])
        #expect(store.stats().donationReadBytes > 0)
        #expect(store.stats().filesWritten == 1)
        #expect(store.stats().corruptDropped == 0)
        #expect(store.config.epochStore?.current == epoch)
        #expect(try Data(contentsOf: file) == original)
        for identifier: UInt64 in [101, 102] {
            let staged = try #require(store.takeStaged(requestID: .init(identifier), tokens: fixture.tokens,
                                                       cacheSalt: "tenant-a", maximumSequenceLength: 521))
            #expect(try staged.manifest == fixture.manifest())
            staged.close()
            store.completeStaging(requestID: .init(identifier))
        }
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
        #expect(fixture.codec.admission.bytesReserved == 0)
    }

    @Test("cancelling an active reader keeps its lease until it unwinds; a queued writer follows it")
    func activeCancellation() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        defer { store.close() }
        #expect(try await fixture.donate(store) == [256])
        let file = fixture.file(store)
        let barrier = SSDCheckpointCoordinationTestSupport.Barrier()
        defer { barrier.release() }
        let first = Task.detached {
            await store.stage(requestID: .init(151), request: fixture.request(), reserveReadScratch: fixture.reserveReadScratch) { manifest in
                try barrier.block()
                return try fixture.plan(manifest)
            }
        }
        defer { first.cancel(); barrier.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { barrier.isEntered }
        let second = await store.stage(requestID: .init(152), request: fixture.request(),
                                       reserveReadScratch: fixture.reserveReadScratch, makeImportPlan: fixture.plan)
        #expect(second.staged)
        // Duplicate validation of the same file is exclusive: it queues behind the first reader.
        let writer = try fixture.startDonation(store, receipt: 153)
        defer { writer.cancel() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { store.fileCoordinator.pendingCount(for: file) == 1 }
        first.cancel()
        #expect(store.fileCoordinator.pendingCount(for: file) == 1)
        #expect(store.stats().donationReadBytes == 0)
        barrier.release()
        #expect(await first.value.disposition == .skippedPolicy)
        #expect(await writer.value == [256])
        #expect(store.stats().donationReadBytes > 0)
        #expect(store.stats().filesRead == 4)
        #expect(store.stats().corruptDropped == 0)
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
    }

    @Test("a writer queued behind a reader goes before readers that arrive after it")
    func queuedWriterPrecedesLaterReaders() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        defer { store.close() }
        #expect(try await fixture.donate(store) == [256])
        let file = fixture.file(store)
        let barrier = SSDCheckpointCoordinationTestSupport.Barrier()
        defer { barrier.release() }
        let reader = Task.detached {
            await store.stage(requestID: .init(171), request: fixture.request(), reserveReadScratch: fixture.reserveReadScratch) { manifest in
                try barrier.block()
                return try fixture.plan(manifest)
            }
        }
        defer { reader.cancel(); barrier.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { barrier.isEntered }
        let writer = try fixture.startDonation(store, receipt: 172)
        defer { writer.cancel() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { store.fileCoordinator.pendingCount(for: file) == 1 }
        let validatedBeforeLateRead = Observation()
        let late = Task.detached {
            await store.stage(requestID: .init(173), request: fixture.request(), reserveReadScratch: fixture.reserveReadScratch) { manifest in
                validatedBeforeLateRead.record(store.stats().donationReadBytes)
                return try fixture.plan(manifest)
            }
        }
        defer { late.cancel() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { store.fileCoordinator.pendingCount(for: file) == 2 }
        #expect(validatedBeforeLateRead.value == nil, "the late reader waits behind the queued writer")
        barrier.release()
        #expect(await reader.value.staged)
        #expect(await writer.value == [256])
        #expect(await late.value.staged)
        let validated = store.stats().donationReadBytes
        #expect(validated > 0 && validatedBeforeLateRead.value == validated)
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
    }

    @Test("retirement, eviction and scans skip a checkpoint while a reader holds it")
    func readersBlockRetirementAndScans() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        defer { store.close() }
        #expect(try await fixture.donate(store) == [256])
        #expect(try await fixture.donate(store, position: 512) == [512])
        let held = fixture.file(store, position: 512), idle = fixture.file(store)
        let barrier = SSDCheckpointCoordinationTestSupport.Barrier()
        defer { barrier.release() }
        let reader = Task.detached {
            await store.stage(requestID: .init(181), request: fixture.request(), reserveReadScratch: fixture.reserveReadScratch) { manifest in
                try barrier.block()
                return try fixture.plan(manifest)
            }
        }
        defer { reader.cancel(); barrier.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { barrier.isEntered }
        #expect(store.retireOwnedEntries([held, idle]) == [idle.path])
        #expect(store.evictOldestEntry() == 0)
        #expect(store.index.count == 1 && FileManager.default.fileExists(atPath: held.path))
        let scanner = try fixture.makeStore()
        #expect(scanner.stats().entries == 0, "a scan never indexes a file another lease holds")
        await scanner.closeAndWait()
        barrier.release()
        #expect(await reader.value.stagedTokens == 512)
        #expect(store.retireOwnedEntries([held]) == [held.path])
        #expect(!FileManager.default.fileExists(atPath: held.path))
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
    }

    @Test("a corrupt checkpoint is removed only by a reader holding it alone")
    func corruptFileRemovedBySoleReader() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        defer { store.close() }
        #expect(try await fixture.donate(store) == [256])
        let file = fixture.file(store)
        let tag = try #require(SSDPrefixCache.hexDecode(file.deletingPathExtension().lastPathComponent))
        var ciphertext = try Data(contentsOf: file)
        ciphertext[ciphertext.count - 1] ^= 1
        try ciphertext.write(to: file)
        let barrier = SSDCheckpointCoordinationTestSupport.Barrier()
        defer { barrier.release() }
        let first = Task.detached {
            await store.stage(requestID: .init(191), request: fixture.request(), reserveReadScratch: fixture.reserveReadScratch) { manifest in
                try barrier.block()
                return try fixture.plan(manifest)
            }
        }
        defer { first.cancel(); barrier.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { barrier.isEntered }
        let second = await store.stage(requestID: .init(192), request: fixture.request(),
                                       reserveReadScratch: fixture.reserveReadScratch, makeImportPlan: fixture.plan)
        #expect(second.disposition == .missCorrupt)
        #expect(FileManager.default.fileExists(atPath: file.path), "another reader still holds the file")
        #expect(store.index.contains(tag16: tag) && store.stats().corruptDropped == 0)
        barrier.release()
        #expect(await first.value.disposition == .missCorrupt)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!store.index.contains(tag16: tag) && store.stats().corruptDropped == 1)
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
    }

    @Test("queued cancellation, abandon, completion, and close drain without reading", arguments: ["cancel", "abandon", "complete", "close"])
    func queuedLifecycle(action: String) async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        defer { store.close() }
        #expect(try await fixture.donate(store) == [256])
        let file = fixture.file(store)
        let owner = store.fileCoordinator.makeAccess(to: file)
        try await owner.acquire()
        defer { owner.release() }
        let stage = Task.detached {
            await store.stage(requestID: .init(201), request: fixture.request(), reserveReadScratch: fixture.reserveReadScratch) { _ in
                Issue.record("cancelled waiter reached import planning")
                throw CBv2CompleteCheckpointError.invalidManifest
            }
        }
        defer { stage.cancel() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { store.fileCoordinator.pendingCount(for: file) == 1 }
        switch action {
        case "cancel": stage.cancel()
        case "abandon": await store.abandonStaging(requestID: .init(201))
        case "complete": store.completeStaging(requestID: .init(201))
        default: store.close()
        }
        #expect(await stage.value.disposition == .skippedPolicy)
        await store.closeAndWait()
        #expect(store.fileCoordinator.pendingCount(for: file) == 0)
        #expect(store.stats().filesRead == 0)
        #expect(store.stats().stagedBytesInUse == 0)
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
        #expect(fixture.codec.admission.bytesReserved == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
        owner.release()
        let retirement = try #require(store.fileCoordinator.tryAcquire(to: file),
                                      "the withdrawn reader left neither a holder nor a waiter")
        retirement.release()
    }

    @Test("queued reads recheck TTL and index membership before I/O", arguments: [false, true])
    func queuedValidity(removal: Bool) async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        defer { store.close() }
        #expect(try await fixture.donate(store) == [256])
        let file = fixture.file(store)
        let epoch = try #require(store.config.epochStore?.current)
        let owner = store.fileCoordinator.makeAccess(to: file)
        try await owner.acquire()
        defer { owner.release() }
        let stage = Task.detached {
            await store.stage(requestID: .init(301), request: fixture.request(),
                              reserveReadScratch: fixture.reserveReadScratch, makeImportPlan: fixture.plan)
        }
        defer { stage.cancel() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { store.fileCoordinator.pendingCount(for: file) == 1 }
        if removal {
            // A whole-root removal of the queued file reconciles the index
            // before the barrier lifts; the epoch is untouched, so the reader
            // sees an ordinary miss rather than a suppressed cache.
            var unlinked = false
            #expect(store.performExternalDestructiveChange {
                unlinked = SSDBlockStore.removeItemIfSafe(at: file, under: fixture.root)
            })
            #expect(unlinked)
            #expect(store.index.count == 0)
        } else {
            store.index.touch(tags16: store.index.allTags(), now: 1)
        }
        owner.release()
        #expect(await stage.value.disposition == .missAbsent)
        #expect(store.config.epochStore?.current == epoch)
        #expect(store.prefixCacheV2Capability()?.cacheEpoch == epoch)
        #expect(store.stats().filesRead == 0)
        #expect(store.stats().corruptDropped == 0)
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
    }

    @Test("same-file coordination spans store instances without a model-wide lock")
    func multipleStoresAndFiles() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let first = try fixture.makeStore()
        defer { first.close() }
        #expect(try await fixture.donate(first) == [256])
        #expect(try await fixture.donate(first, position: 512) == [512])
        let second = try fixture.makeStore()
        defer { second.close() }
        let file = fixture.file(first, position: 512)
        let owner = first.fileCoordinator.makeAccess(to: file)
        try await owner.acquire()
        defer { owner.release() }
        let stage = Task.detached {
            await second.stage(requestID: .init(401), request: fixture.request(),
                               reserveReadScratch: fixture.reserveReadScratch, makeImportPlan: fixture.plan)
        }
        defer { stage.cancel() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { first.fileCoordinator.pendingCount(for: file) == 1 }
        let otherFile = first.fileCoordinator.makeAccess(to: fixture.file(first))
        try await otherFile.acquire()
        otherFile.release()
        await second.closeAndWait()
        #expect(await stage.value.disposition == .skippedPolicy)
        owner.release()
        let result = await first.stage(requestID: .init(402), request: fixture.request(),
                                       reserveReadScratch: fixture.reserveReadScratch, makeImportPlan: fixture.plan)
        #expect(result.staged)
        await first.closeAndWait()
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
    }
}
