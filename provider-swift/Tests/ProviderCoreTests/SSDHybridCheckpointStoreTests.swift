import Foundation
import MLX
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Complete checkpoint encrypted SSD lifecycle", .serialized)
struct SSDHybridCheckpointStoreTests {
    @Test("idle misses do no file reads or native allocations")
    func missDoesNotRead() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let store = try f.makeStore()
        let result = await store.stage(requestID: .init(1), request: f.request(), reserveReadScratch: f.reserveReadScratch) { _ in
            Issue.record("miss tried to allocate"); throw CBv2CompleteCheckpointError.invalidManifest
        }
        #expect(!result.staged)
        #expect(store.stats().filesRead == 0)
        #expect(store.stats().stagedBytesInUse == 0)
        await store.closeAndWait()
    }

    @Test("commit releases export arrays; restart restores exact tensors only for matching tenant")
    func restartAndTenant() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let first = try f.makeStore()
        let source = try f.source()
        let positions = await withCheckedContinuation { continuation in
            first.donate(source, requestID: .init(9), tokens: f.tokens, cacheSalt: "tenant-a") { continuation.resume(returning: $0) }
        }
        #expect(positions == [256])
        #expect(throws: CBv2CompleteCheckpointError.closed) { try source.readSegment(tensorIndex: 0, byteOffset: 0, maximumBytes: 8) }
        #expect(first.stats().stagedBytesInUse == 0)
        await first.closeAndWait()
        let second = try f.makeStore()
        #expect(second.stats().entries == 1)
        #expect(second.stats().filesRead == 0)
        let wrong = await second.stage(requestID: .init(10), request: f.request(scope: "tenant-b"), reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(!wrong.staged)
        #expect(second.stats().filesRead == 0)
        let result = await second.stage(requestID: .init(11), request: f.request(), reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(result.staged)
        let stage = try #require(second.takeStaged(requestID: .init(11), tokens: f.tokens, cacheSalt: "tenant-a", maximumSequenceLength: 521))
        #expect(second.takeStaged(requestID: .init(11), tokens: f.tokens, cacheSalt: "tenant-a", maximumSequenceLength: 521) == nil)
        try stage.consumePreparedState { prepared in
            let recurrent = try #require(prepared.checkpoint?.layers[1])
            #expect(recurrent.conv?.asArray(Float.self) == Array(repeating: 3, count: 4))
            #expect(recurrent.ssm?.asArray(Float.self) == Array(repeating: 4, count: 8))
            let kv = try #require(prepared.state.first.flatMap { $0 })
            #expect(kv.absoluteOffset == 256)
            let full = try #require(kv as? CBv2FullSequenceKV)
            let arrays = full.cbv2InnerState()
            #expect(arrays[0][.ellipsis, ..<256, 0...].asArray(Float.self) == Array(repeating: 1, count: 512))
            #expect(arrays[1][.ellipsis, ..<256, 0...].asArray(Float.self) == Array(repeating: 2, count: 512))
        }
        await second.closeAndWait()
        #expect(second.stats().stagedBytesInUse == 0)
        #expect(await f.budget.outstandingReservedBytes() == 0)
    }

    @Test("authenticated repeat avoids another decrypt and never rewrites durable bytes")
    func repeatDeduplicates() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let store = try f.makeStore()
        #expect(try await f.donate(store) == [256])
        let result = await store.stage(requestID: .init(21), request: f.request(), reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(result.staged)
        #expect(try await f.donate(store, receipt: 21) == [256])
        #expect(store.stats().filesWritten == 1)
        #expect(store.stats().donationReadBytes == 0)
        await store.abandonStaging(requestID: .init(21))
        #expect(store.stats().stagedBytesInUse == 0)
        #expect(await f.budget.outstandingReservedBytes() == 0)
        await store.closeAndWait()
    }

    @Test("allocation refusal preserves authenticated disk data and releases staging")
    func allocationFailureKeepsFile() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let store = try f.makeStore()
        #expect(try await f.donate(store) == [256])
        let result = await store.stage(requestID: .init(31), request: f.request(), reserveReadScratch: f.reserveReadScratch) { manifest in
            let plan = try f.plan(manifest)
            plan.evaluateDestinations = { _ in throw CBv2CompleteCheckpointError.allocationFailed }
            return plan
        }
        #expect(result.disposition == .skippedCapacity)
        #expect(store.stats().entries == 1)
        #expect(store.stats().corruptDropped == 0)
        #expect(FileManager.default.fileExists(atPath: f.file(store).path))
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
        #expect(await f.budget.outstandingReservedBytes() == 0)
    }

    @Test("late ciphertext corruption never publishes a stage ticket")
    func corruptionIsCold() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let store = try f.makeStore()
        #expect(try await f.donate(store) == [256])
        let file = f.file(store)
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: file)
        let result = await store.stage(requestID: .init(41), request: f.request(), reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(result.disposition == .missCorrupt)
        #expect(store.takeStaged(requestID: .init(41), tokens: f.tokens, cacheSalt: "tenant-a", maximumSequenceLength: 521) == nil)
        #expect(store.stats().entries == 0)
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
        #expect(await f.budget.outstandingReservedBytes() == 0)
    }

    @Test("capture policy reserves manifest bound and rejects unusable latest checkpoints")
    func captureEligibility() throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let store = try f.makeStore(readCap: 2 << 20)
        defer { store.close() }
        #expect(store.acceptsCheckpoint(position: 256, packedBytes: 1 << 20))
        #expect(!store.acceptsCheckpoint(position: 512, packedBytes: (1 << 20) + 1))
        #expect(!store.acceptsCheckpoint(position: 255, packedBytes: 1024))
        #expect(!store.acceptsCheckpoint(position: 512, packedBytes: Int.max))
    }
    @Test("changed or deleted authenticated files never refresh durable ready")
    func changedFileCannotUseReceiptProof() async throws {
        for replace in [false, true] {
            let f = try SSDHybridCheckpointTestFixture()
            defer { f.remove() }
            let store = try f.makeStore()
            #expect(try await f.donate(store) == [256])
            let result = await store.stage(requestID: .init(51), request: f.request(), reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
            #expect(result.staged)
            let file = f.file(store)
            if replace {
                var bytes = try Data(contentsOf: file)
                bytes[bytes.count - 1] ^= 1
                try bytes.write(to: file, options: .atomic)
            } else {
                try FileManager.default.removeItem(at: file)
            }
            #expect(try await f.donate(store, receipt: 51).isEmpty)
            #expect(store.stats().filesWritten == 1)
            await store.closeAndWait()
            #expect(store.stats().stagedBytesInUse == 0)
        }
    }

    @Test("disabled and expired candidates do no encrypted payload reads")
    func disabledAndExpiredAreCold() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let store = try f.makeStore()
        #expect(try await f.donate(store) == [256])
        var disabled = f.request()
        disabled.prefixCacheEnabled = false
        let disabledResult = await store.stage(requestID: .init(61), request: disabled, reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(disabledResult.disposition == .skippedPolicy)
        #expect(store.stats().filesRead == 0)
        let tag = try #require(store.index.allTags().first)
        store.index.touch(tags16: [tag], now: 1)
        let expired = await store.stage(requestID: .init(62), request: f.request(), reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(!expired.staged)
        #expect(store.stats().filesRead == 0)
        await store.closeAndWait()
    }

    @Test("close cancels a blocked write without waiting for its completion callback")
    func closeDoesNotWaitOnWrite() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let store = try f.makeStore()
        store.pipeline.shutdown()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        store.pipeline = BoundedSingleConsumerPipeline(capacity: 1,
            onDropped: { store.settle($0, positions: []) }, consume: { job in
                entered.signal()
                // Block in a synchronous disk-worker seam, never on engine queue.
                func block() { release.wait() }
                block()
                store.write(job)
            })
        let donation = Task { try await f.donate(store) }
        func enteredWithoutBlocking() -> Bool { entered.wait(timeout: .now()) == .success }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var didEnter = false
        while ContinuousClock.now < deadline {
            if enteredWithoutBlocking() { didEnter = true; break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(didEnter)
        store.close()
        #expect(store.isClosed)
        release.signal()
        #expect(try await donation.value.isEmpty)
        await store.closeAndWait()
        #expect(store.stats().filesWritten == 0)
        #expect(store.stats().stagedBytesInUse == 0)
    }

    @Test("overlapping stages reauthenticate changed recency without deleting valid ciphertext")
    func overlappingStagesPreserveFile() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let store = try f.makeStore()
        #expect(try await f.donate(store) == [256])
        let first = await store.stage(requestID: .init(71), request: f.request(), reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        let second = await store.stage(requestID: .init(72), request: f.request(), reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(first.staged && second.staged)
        #expect(try await f.donate(store, receipt: 71) == [256])
        #expect(try await f.donate(store, receipt: 72) == [256])
        #expect(store.stats().filesWritten == 1)
        #expect(store.stats().entries == 1)
        #expect(store.stats().corruptDropped == 0)
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
    }

    @Test("complete checkpoint roots share one disk budget and evict through epoch fencing")
    func sharedDiskBudget() async throws {
        let a = try SSDHybridCheckpointTestFixture()
        let b = try SSDHybridCheckpointTestFixture()
        defer { a.remove(); b.remove() }
        let disk = SSDDiskBudget()
        let first = try a.makeStore(diskBudget: disk)
        let second = try b.makeStore(diskBudget: disk)
        #expect(try await a.donate(first) == [256])
        #expect(try await b.donate(second) == [256])
        let limit = max(first.stats().bytesOnDisk, second.stats().bytesOnDisk)
        let before = [first.config.epochStore?.current, second.config.epochStore?.current]
        _ = disk.enforce(budgetBytes: limit)
        #expect(first.stats().bytesOnDisk + second.stats().bytesOnDisk <= limit)
        #expect(first.stats().entries + second.stats().entries == 1)
        #expect(first.stats().evictions + second.stats().evictions == 1)
        #expect([first.config.epochStore?.current, second.config.epochStore?.current] != before)
        await first.closeAndWait()
        await second.closeAndWait()
    }

    @Test("without a global budget the engine scratch refusal still precedes header I/O")
    func engineScratchRefusalBeforeRead() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let store = try f.makeStore(useGlobalBudget: false)
        #expect(try await f.donate(store) == [256])
        let admission = AdmissionV2(layerKinds: f.codec.layerKinds,
            bytesCapacity: CBv2CompleteCheckpointManifest.maximumProviderScratchBytes - 1,
            config: .init(watermarkFraction: 0))
        let result = await store.stage(requestID: .init(81), request: f.request(), reserveReadScratch: {
            .init(reservation: try admission.reserveTransient(bytes: CBv2CompleteCheckpointManifest.maximumProviderScratchBytes))
        }, makeImportPlan: f.plan)
        #expect(result.disposition == .skippedCapacity)
        #expect(store.stats().filesRead == 0)
        #expect(store.stats().entries == 1)
        #expect(admission.bytesReserved == 0)
        await store.closeAndWait()
    }

}
