import Foundation
import MLX
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Durable cache heartbeat telemetry")
struct SSDPrefixCacheTelemetryTests {
    @Test("store observations retain cumulative units and omit unavailable measurements")
    func snapshotFields() throws {
        var stats = SSDHybridCheckpointStats()
        stats.entries = 2; stats.bytesOnDisk = 4096; stats.stagedBytesInUse = 0
        stats.stageMilliseconds = 125.125; stats.writeMilliseconds = 250.5
        stats.bytesRead = 4096; stats.stageReadBytes = 3072; stats.donationReadBytes = 1024
        let sample = PrefixCacheTelemetry(complete: stats)
        #expect(sample.io?.stageUsTotal == 125125)
        #expect(sample.io?.writeUsTotal == 250500)
        #expect(sample.io?.stageReadBytesTotal == 3072)
        #expect(sample.stagingBytes == 0)
        #expect(sample.ttlExpiredTotal == nil)
        let attention = PrefixCacheTelemetry(attention: SSDPrefixCacheStats())
        #expect(attention.io == nil)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(attention)) as? [String: Any]
        #expect(json?["kind"] as? String == "attention_blocks")
        #expect(json?["io"] == nil)
        #expect(json?["ttl_expired_total"] as? Int == 0)
        #expect(try JSONDecoder().decode(PrefixCacheTelemetry.self, from: JSONEncoder().encode(sample)) == sample)
    }

    @Test("sample age advances without resampling and reload creates a new baseline")
    func ageAndGeneration() throws {
        let box = SSDPrefixCacheTelemetryBox()
        let start = ContinuousClock.now
        #expect(box.snapshot(now: start) == nil)
        box.publish(.init(complete: SSDHybridCheckpointStats()), now: start)
        let first = try #require(box.snapshot(now: start))
        let later = try #require(box.snapshot(now: start.advanced(by: .seconds(90))))
        #expect(later.sampleSeq == first.sampleSeq)
        #expect(later.sampleAgeMs == 90000)
        box.publish(.init(complete: SSDHybridCheckpointStats()), now: start.advanced(by: .seconds(120)))
        let fresh = try #require(box.snapshot(now: start.advanced(by: .seconds(120))))
        #expect(fresh.sampleSeq == first.sampleSeq + 1)
        #expect(fresh.sampleAgeMs == 0)
        box.close()
        box.publish(.init(complete: SSDHybridCheckpointStats()))
        #expect(box.snapshot() == nil)
        let replacement = SSDPrefixCacheTelemetryBox()
        replacement.publish(.init(complete: SSDHybridCheckpointStats()))
        #expect(replacement.snapshot()?.generation != first.generation)
    }

    @Test("legacy capacity omits new fields; heartbeat round trip retains typed counters")
    func capacityWire() throws {
        var slot = BackendSlotCapacity(model: "model", state: "idle", numRunning: 0,
            numWaiting: 0, activeTokens: 0, maxTokensPotential: 1024)
        let oldJSON = String(decoding: try JSONEncoder().encode(slot), as: UTF8.self)
        #expect(!oldJSON.contains("prefix_cache"))
        slot.prefixCache = PrefixCacheTelemetry(complete: SSDHybridCheckpointStats())
        slot.prefixCache?.generation = 7; slot.prefixCache?.sampleSeq = 2
        var capacity = BackendCapacity(slots: [slot], gpuMemoryActiveGb: 0,
            gpuMemoryPeakGb: 0, gpuMemoryCacheGb: 0, totalMemoryGb: 32)
        capacity.prefixCacheMaintenance = .init(ttlExpiredTotal: 2, budgetEvictedTotal: 3, tempRemovedTotal: 4)
        #expect(try JSONDecoder().decode(BackendCapacity.self, from: JSONEncoder().encode(capacity)) == capacity)
    }
}

private final class CompleteDonationRecorder: PrefixCacheDonationRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PrefixCacheDonationOutcome] = []
    func record(_ outcome: PrefixCacheDonationOutcome) { lock.withLock { values.append(outcome) } }
    var snapshot: [PrefixCacheDonationOutcome] { lock.withLock { values } }
}

@Suite("Complete checkpoint donation telemetry", .serialized)
struct SSDCompleteDonationTelemetryTests {
    @Test("durable, duplicate and failed authentication settle once with source released")
    func durableAndFailed() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let recorder = CompleteDonationRecorder()
        let store = try f.makeStore(donationRecorder: recorder)
        #expect(try await f.donate(store) == [256])
        #expect(try await f.donate(store, receipt: 11) == [256])
        var bytes = try Data(contentsOf: f.file(store))
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: f.file(store))
        #expect(try await f.donate(store, receipt: 12).isEmpty)
        await store.closeAndWait()
        #expect(recorder.snapshot == [.donated, .alreadyDurable, .writeFailed])
    }

    @Test("whole-root removals accumulate once, including an unloaded complete store")
    func maintenanceTotals() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let store = try f.makeStore()
        #expect(try await f.donate(store) == [256])
        await store.closeAndWait()
        let maintainer = SSDWholeRootMaintainer()
        let now = Int64(Date().timeIntervalSince1970) + 7200
        let first = maintainer.maintain(root: f.root, ttlSeconds: 3600, nowSeconds: now, budgetBytes: Int.max)
        #expect(first.ttlExpired == 1)
        _ = maintainer.maintain(root: f.root, ttlSeconds: 3600, nowSeconds: now, budgetBytes: Int.max)
        let snapshot = PrefixCacheMaintenanceTelemetry(maintainer.statsSnapshot())
        #expect(snapshot.ttlExpiredTotal == 1)
        #expect(snapshot.budgetEvictedTotal == 0)
    }

    @Test("synchronous refusal and rate limit produce distinct bounded outcomes")
    func refusals() async throws {
        for (cap, rate, close, expected) in [
            (1, 1 << 30, false, PrefixCacheDonationOutcome.stageSizeExceeded),
            (16 << 20, 1, false, .writeRateLimited),
            (16 << 20, 1 << 30, true, .cacheClosed),
        ] {
            let f = try SSDHybridCheckpointTestFixture()
            defer { f.remove() }
            let recorder = CompleteDonationRecorder()
            let store = try f.makeStore(readCap: cap, maxWriteBytesPerDay: rate, donationRecorder: recorder)
            if close { store.close() }
            let source = try f.source()
            let positions: [Int] = await withCheckedContinuation { continuation in
                store.donate(source, requestID: .init(21), tokens: f.tokens, cacheSalt: "tenant-a") {
                    continuation.resume(returning: $0)
                }
            }
            #expect(positions.isEmpty)
            #expect(throws: CBv2CompleteCheckpointError.closed) {
                try source.readSegment(tensorIndex: 0, byteOffset: 0, maximumBytes: 8)
            }
            await store.closeAndWait()
            #expect(recorder.snapshot == [expected])
        }
    }

    @Test("queued duplicate, queue refusal and shutdown each settle exactly once")
    func closeAndQueue() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let recorder = CompleteDonationRecorder()
        let store = try f.makeStore(donationRecorder: recorder)
        store.pipeline.shutdown()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal(); store.close() }
        store.pipeline = BoundedSingleConsumerPipeline(capacity: 1,
            onDropped: { store.settle($0, positions: []) }, consume: { job in
                entered.signal()
                func wait() { release.wait() }
                wait(); store.write(job)
            })
        let first = Task { try await f.donate(store) }
        func isEntered() -> Bool { entered.wait(timeout: .now()) == .success }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var started = false
        while ContinuousClock.now < deadline {
            if isEntered() { started = true; break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(started)
        #expect(try await f.donate(store, receipt: 22).isEmpty)
        // Enqueue a different real checkpoint without waiting on its callback.
        let source = try f.source(position: 512)
        store.donate(source, requestID: .init(23), tokens: f.tokens, cacheSalt: "tenant-a") { _ in }
        let third = try f.source(scope: "tenant-b")
        store.donate(third, requestID: .init(24), tokens: f.tokens, cacheSalt: "tenant-b") { positions in
            #expect(positions.isEmpty)
        }
        store.close()
        release.signal()
        #expect(try await first.value.isEmpty)
        await store.closeAndWait()
        let values = recorder.snapshot
        #expect(values.count == 4)
        #expect(values.filter { $0 == .alreadyQueued }.count == 1)
        #expect(values.filter { $0 == .writeQueueFull }.count == 1)
        #expect(values.filter { $0 == .cacheClosed }.count == 2)
        #expect(store.stats().filesWritten == 0)
    }
}
