import Foundation
import MLX
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Complete checkpoint coordinated staging", .serialized)
struct SSDHybridCheckpointCoordinationTests {
    @Test("two same-file stages succeed and changed receipts still reauthenticate", arguments: [false, true])
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
        let barrier = SSDCheckpointCoordinationTestSupport.Barrier()
        defer { barrier.release() }
        let first = Task.detached {
            await store.stage(requestID: .init(101), request: fixture.request(), reserveReadScratch: fixture.reserveReadScratch) { manifest in
                try barrier.block()
                return try fixture.plan(manifest)
            }
        }
        defer { first.cancel(); barrier.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { barrier.isEntered }
        let second = Task.detached {
            await store.stage(requestID: .init(102), request: fixture.request(),
                              reserveReadScratch: fixture.reserveReadScratch, makeImportPlan: fixture.plan)
        }
        defer { second.cancel() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { store.fileCoordinator.pendingCount(for: file) == 1 }
        #expect(store.stats().filesRead == 1)
        #expect(store.stats().stagedBytesInUse == 2 * SSDHybridCheckpointStore.ioScratchBytes)
        barrier.release()
        #expect(await first.value.staged)
        #expect(await second.value.staged)
        #expect(store.stats().filesRead == 4)
        #expect(try await fixture.donate(store, receipt: 101) == [256])
        let reauthenticatedBytes = store.stats().donationReadBytes
        #expect(reauthenticatedBytes > 0)
        #expect(try await fixture.donate(store, receipt: 102) == [256])
        #expect(store.stats().donationReadBytes == reauthenticatedBytes)
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

    @Test("cancelling the active reader holds exclusion until unwind and lets its successor stage")
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
        let second = Task.detached {
            await store.stage(requestID: .init(152), request: fixture.request(),
                              reserveReadScratch: fixture.reserveReadScratch, makeImportPlan: fixture.plan)
        }
        defer { second.cancel() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { store.fileCoordinator.pendingCount(for: file) == 1 }
        first.cancel()
        #expect(store.fileCoordinator.pendingCount(for: file) == 1)
        barrier.release()
        #expect(await first.value.disposition == .skippedPolicy)
        #expect(await second.value.staged)
        #expect(store.stats().filesRead == 3)
        #expect(store.stats().corruptDropped == 0)
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
    }

    @Test("queued reads recheck TTL and epoch before I/O", arguments: [false, true])
    func queuedValidity(epochChange: Bool) async throws {
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
            await store.stage(requestID: .init(301), request: fixture.request(),
                              reserveReadScratch: fixture.reserveReadScratch, makeImportPlan: fixture.plan)
        }
        defer { stage.cancel() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { store.fileCoordinator.pendingCount(for: file) == 1 }
        if epochChange {
            #expect(store.performExternalDestructiveChange({}))
        } else {
            store.index.touch(tags16: store.index.allTags(), now: 1)
        }
        owner.release()
        #expect(await stage.value.disposition == (epochChange ? .skippedPolicy : .missAbsent))
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
