import Foundation
import MLX
import Testing
@testable import MLXLMCommon
@testable import ProviderCore

@Suite("Shared process paged SSD ownership", .serialized)
struct SSDSharedProcessCheckpointTests {
    private static func wait(_ semaphore: DispatchSemaphore,
                             until deadline: DispatchTime = .distantFuture) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: deadline) == .success)
            }
        }
    }

    @Test("a bound engine with missing host authority refuses before the first manifest byte")
    func missingHostAuthority() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(sharedPaged: true)
        defer { fixture.remove() }
        let original = try fixture.makeStore()
        #expect(try await fixture.donate(original) == [256])
        await original.closeAndWait()
        let miswired = try fixture.makeStore(useGlobalBudget: false)
        let result = await miswired.stage(
            requestID: .init(80), request: fixture.request(), reserveReadScratch: fixture.reserveReadScratch
        ) { _ in
            Issue.record("missing host authority reached import planning")
            throw CBv2CompleteCheckpointError.invalidManifest
        }
        #expect(result.disposition == .skippedCapacity)
        #expect(miswired.stats().filesRead == 0)
        #expect(miswired.stats().bytesRead == 0)
        #expect(fixture.codec.admission.bytesReserved == 0)
        await miswired.closeAndWait()
        fixture.codec.admission.closeProcessMemoryOwner()
    }

    @Test("store close retains the in-flight writer envelope until its consumer returns")
    func writeCloseRetainsHostOwner() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(sharedPaged: true)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        store.pipeline.shutdown()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        store.pipeline = BoundedSingleConsumerPipeline(
            capacity: 1, onDropped: { store.settle($0, positions: []) },
            consume: { job in
                entered.signal()
                _ = await Self.wait(release)
                store.write(job)
            })
        let donation = Task { try await fixture.donate(store) }
        let arrived = await Self.wait(entered, until: .now() + 5)
        #expect(arrived)
        if arrived {
            #expect(fixture.budget.processLedger.snapshot().chargedBytes
                == UInt64(SSDHybridCheckpointStore.ioScratchBytes))
            store.close()
            #expect(store.stats().writeHostBytesInUse == SSDHybridCheckpointStore.ioScratchBytes)
            #expect(fixture.budget.processLedger.snapshot().chargedBytes
                == UInt64(SSDHybridCheckpointStore.ioScratchBytes))
        }
        release.signal()
        #expect(try await donation.value.isEmpty)
        await store.closeAndWait()
        #expect(store.stats().writeHostBytesInUse == 0)
        #expect(fixture.budget.processLedger.snapshot().chargedBytes == 0)
        fixture.codec.admission.closeProcessMemoryOwner()
    }

    @Test("Read completion retires only host IO; native stage retains its own charge")
    func stageOwnership() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(sharedPaged: true)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        #expect(try await fixture.donate(store) == [256])
        #expect(store.stats().writeHostBytesInUse == 0)
        #expect(store.stats().peakWriteHostBytes == SSDHybridCheckpointStore.ioScratchBytes)
        // Planning owns its manifest. Return only scalar prices so this probe
        // does not keep a second metadata permit alive during the actual stage.
        func prices() throws -> (destination: Int, scratch: Int, metadata: Int) {
            let plan = try fixture.plan(fixture.manifest())
            #expect(plan.usesProcessMemoryOwner)
            let permit = try #require(plan.manifest.metadata.permit)
            return (plan.nativeDestinationBytes, plan.scratchBytes, permit.bytes)
        }
        let price = try prices()
        let result = await store.stage(
            requestID: .init(81), request: fixture.request(),
            reserveReadScratch: fixture.reserveReadScratch, makeImportPlan: fixture.plan)
        #expect(result.staged)
        let shared = fixture.budget.processLedger.snapshot()
        #expect(shared.chargedBytes == UInt64(fixture.codec.admission.bytesReserved))
        #expect(result.deviceBytes > 0 && result.deviceBytes <= price.destination)
        #expect(shared.chargedBytes == UInt64(result.deviceBytes + price.scratch + price.metadata))
        #expect(shared.materializedBytes > 0)
        #expect(store.stats().stagedBytesInUse == 0)
        #expect(store.stats().peakStagingReservationBytes == SSDHybridCheckpointStore.ioScratchBytes)
        func retireStage() throws {
            let staged = try #require(store.takeStaged(
                requestID: .init(81), tokens: fixture.tokens, cacheSalt: "tenant-a", maximumSequenceLength: 521))
            #expect(staged.nativeDestinationBytes == result.deviceBytes)
            let footprint = try measureAndRetire(staged)
            #expect(footprint.destination == result.deviceBytes)
            #expect(shared.materializedBytes == UInt64(footprint.pages))
            #expect(fixture.budget.processLedger.snapshot().chargedBytes == UInt64(price.metadata))
            #expect(fixture.budget.processLedger.snapshot().materializedBytes == 0)
        }
        try retireStage()
        await store.closeAndWait()
        #expect(fixture.budget.processLedger.snapshot().chargedBytes == 0)
        #expect(fixture.budget.processLedger.snapshot().materializedBytes == 0)
        fixture.codec.admission.closeProcessMemoryOwner()
        #expect(fixture.budget.processLedger.snapshot().ownerCount == 0)
    }

    @Test("Host capacity refusal closes the donor before any write is queued")
    func writeHostRefusal() async throws {
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0, memorySnapshot: {
            .init(total: (2 << 30) + UInt64(SSDHybridCheckpointStore.ioScratchBytes) - 1,
                  active: 0, cache: 0, systemAvailable: .max)
        })
        let fixture = try SSDHybridCheckpointTestFixture(sharedPaged: true, budget: budget)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        let source = try fixture.source()
        let positions: [Int] = await withCheckedContinuation { continuation in
            store.donate(source, requestID: .init(82), tokens: fixture.tokens, cacheSalt: "tenant-a") {
                continuation.resume(returning: $0)
            }
        }
        #expect(positions.isEmpty)
        #expect(store.stats().writeHostCapacityRefusals == 1)
        #expect(store.stats().writeHostBytesInUse == 0)
        #expect(store.stats().filesWritten == 0)
        #expect(throws: CBv2CompleteCheckpointError.closed) {
            try source.readSegment(tensorIndex: 0, byteOffset: 0, maximumBytes: 4)
        }
        await store.closeAndWait()
        #expect(budget.processLedger.snapshot().chargedBytes == 0)
        fixture.codec.admission.closeProcessMemoryOwner()
    }

    @Test("Failed native allocation drains both owners and preserves authenticated ciphertext")
    func allocationFailure() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(sharedPaged: true)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        #expect(try await fixture.donate(store) == [256])
        let result = await store.stage(
            requestID: .init(83), request: fixture.request(), reserveReadScratch: fixture.reserveReadScratch
        ) { manifest in
            let plan = try fixture.plan(manifest)
            plan.evaluateDestinations = { _ in throw CBv2CompleteCheckpointError.allocationFailed }
            return plan
        }
        #expect(result.disposition == .skippedCapacity)
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
        #expect(store.stats().corruptDropped == 0)
        #expect(store.stats().entries == 1)
        #expect(fixture.budget.processLedger.snapshot().chargedBytes == 0)
        #expect(fixture.budget.processLedger.snapshot().materializedBytes == 0)
        fixture.codec.admission.closeProcessMemoryOwner()
    }
    /// Independently inspect the actual evaluated backing while the moved
    /// native owner still owns every alias. This is an observation, never a
    /// new materialization credit or a sum of logical tensor nbytes.
    private func measureAndRetire(_ staged: CBv2StagedCompleteCheckpoint)
        throws -> (destination: Int, pages: Int)
    {
        try staged.consumePreparedState { prepared in
            let frame = try #require(prepared.pagedFrame)
            prepared.pagedFrame = nil
            let owner = try frame.consume()
            defer { owner.close() }
            var pages = 0
            for group in owner.storage.groups.values {
                for segment in group.segments.values {
                    let observed = try segment.storage.evaluatedBufferInfo()
                    let info = try #require(observed)
                    #expect(info.allocatedBytes == segment.allocatedBytes)
                    pages += info.allocatedBytes
                }
            }
            var auxiliary = 0
            for array in owner.auxiliary {
                let observed = try array.evaluatedBufferInfo()
                let info = try #require(observed)
                auxiliary += info.allocatedBytes
                #expect(info.allocatedBytes >= array.nbytes)
            }
            return (pages + auxiliary, pages)
        }
    }

    @Test("Unbound paged staging retains actual destination bytes after the peak envelope retires")
    func nonsharedActualDestination() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(paged: true)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        #expect(try await fixture.donate(store) == [256])
        func bound() throws -> Int { try fixture.plan(fixture.manifest()).nativeDestinationBytes }
        let upperBound = try bound()
        let result = await store.stage(requestID: .init(84), request: fixture.request(),
            reserveReadScratch: fixture.reserveReadScratch, makeImportPlan: fixture.plan)
        #expect(result.staged && result.deviceBytes > 0 && result.deviceBytes <= upperBound)
        #expect(store.stats().stagedBytesInUse == result.deviceBytes)
        #expect(fixture.budget.processLedger.snapshot().chargedBytes == UInt64(result.deviceBytes))
        func retire() throws {
            let staged = try #require(store.takeStaged(requestID: .init(84), tokens: fixture.tokens,
                cacheSalt: "tenant-a", maximumSequenceLength: 521))
            #expect(staged.nativeDestinationBytes == result.deviceBytes)
            let measured = try measureAndRetire(staged)
            #expect(measured.destination == result.deviceBytes)
        }
        try retire()
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
        #expect(fixture.budget.processLedger.snapshot().chargedBytes == 0)
        #expect(fixture.codec.admission.bytesReserved == 0)
    }

}
