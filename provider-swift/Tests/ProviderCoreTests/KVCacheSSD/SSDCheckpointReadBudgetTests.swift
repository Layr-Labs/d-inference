import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

final class SSDCheckpointTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}

@Suite("Complete-checkpoint retry raw-read and clock bounds")
struct SSDCheckpointReadBudgetTests {
    @Test func firstAttemptKeepsItsExistingLimits() throws {
        let clock = SSDCheckpointTestClock()
        let budget = SSDCheckpointReadBudget(maximumBytes: 10, maximumMillis: 1,
            started: clock.now(), now: clock.now)
        clock.advance(.seconds(2))
        try budget.beforeRead(11)
        try budget.checkTime()
        #expect(budget.consumedBytes == 11)
        #expect(!budget.beginRetry(estimatedFileBytes: 0))
        try budget.beforeRead(Int.max)
        #expect(budget.consumedBytes == Int.max, "first-leg accounting saturates without changing admission")
    }

    @Test func exactRemainingBytesAndOneRetry() throws {
        let clock = SSDCheckpointTestClock()
        let budget = SSDCheckpointReadBudget(maximumBytes: 10, maximumMillis: 1000,
            started: clock.now(), now: clock.now)
        try budget.beforeRead(4)
        #expect(budget.beginRetry(estimatedFileBytes: 6))
        #expect(!budget.beginRetry(estimatedFileBytes: 0))
        try budget.beforeRead(6)
        #expect(budget.consumedBytes == 10)
        #expect(throws: SSDCheckpointReadBudget.Exhausted.self) { try budget.beforeRead(1) }
        #expect(throws: SSDCheckpointReadBudget.Exhausted.self) { try budget.beforeRead(-1) }
        #expect(budget.consumedBytes == 10)
    }

    @Test func deadlineIsOriginalStartAndStrictAtBoundary() throws {
        let clock = SSDCheckpointTestClock()
        let budget = SSDCheckpointReadBudget(maximumBytes: 1024, maximumMillis: 1000,
            started: clock.now(), now: clock.now)
        clock.advance(.milliseconds(999))
        #expect(budget.beginRetry(estimatedFileBytes: 0))
        try budget.beforeRead(1)
        clock.advance(.milliseconds(1))
        #expect(throws: SSDCheckpointReadBudget.Exhausted.self) { try budget.beforeRead(0) }
        #expect(budget.consumedBytes == 1)
        let expired = SSDCheckpointReadBudget(maximumBytes: 1024, maximumMillis: 0,
            started: clock.now(), now: clock.now)
        #expect(!expired.beginRetry(estimatedFileBytes: 0))
        let estimateClock = SSDCheckpointTestClock()
        let estimate = SSDCheckpointReadBudget(maximumBytes: 16 << 20, maximumMillis: 1000,
            started: estimateClock.now(), now: estimateClock.now)
        estimateClock.advance(.milliseconds(999))
        #expect(!estimate.beginRetry(estimatedFileBytes: 3 << 20),
            "remaining time must also cover the existing estimated file cost")
    }

    private enum Probe: Error { case done }

    @Test("framing, first probe and the final EOF byte all share one ceiling", arguments: [0, 1])
    func streamingChargesFramingAndEOF(_ missingBytes: Int) throws {
        let root = try SSDTestDirectory.parent().appendingPathComponent("retry-read-bound-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("0123456789ab")
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: model)
        let file = SSDBlockStore.fileURL(root: model, tag16Hex: String(repeating: "a", count: 32))
        let key = SymmetricKey(size: .bits256)
        let chunks = [Data(repeating: 1, count: 19), Data(repeating: 2, count: 37)]
        let metadata = SSDBlockMetadata(lookupTag: String(repeating: "a", count: 64), weightHash: "fixture",
            layoutEpoch: "retry-bound", blockSize: 256, layerCount: 1,
            chunks: chunks.enumerated().map { .init(layerIndex: 0, tensor: $0.offset,
                shape: [$0.element.count], dtype: "uint8") }, chunkPlaintextSizes: chunks.map(\.count), createdAt: 1)
        let fileBytes = try SSDBlockStore.writeStreaming(to: file, metadata: metadata, kekKey: key,
            maximumChunkBytes: 37, chunk: { chunks[$0] })
        var firstBytes = 0
        do {
            try SSDBlockStore.readStreaming(from: file, kekKey: key, maximumChunkBytes: 37,
                maximumPlaintextBytes: 56, onBytesRead: { firstBytes += $0 }, validateMetadata: { _ in },
                consumeChunk: { index, data in #expect(index == 0 && data == chunks[0]); throw Probe.done })
            Issue.record("fixture probe did not stop")
        } catch Probe.done { }
        let clock = SSDCheckpointTestClock()
        let ceiling = firstBytes + fileBytes + 1 - missingBytes
        let budget = SSDCheckpointReadBudget(maximumBytes: ceiling, maximumMillis: 1000,
            started: clock.now(), now: clock.now)
        do {
            try SSDBlockStore.readStreaming(from: file, kekKey: key, maximumChunkBytes: 37,
                maximumPlaintextBytes: 56, beforeRead: budget.beforeRead, validateMetadata: { _ in },
                consumeChunk: { _, _ in throw Probe.done })
        } catch Probe.done { }
        #expect(budget.consumedBytes == firstBytes)
        try #require(budget.beginRetry(estimatedFileBytes: fileBytes))
        var received: [Data] = []
        var failed = false
        do {
            try SSDBlockStore.readStreaming(from: file, kekKey: key, maximumChunkBytes: 37,
                maximumPlaintextBytes: 56, requireEOF: true, beforeRead: budget.beforeRead,
                validateMetadata: { _ in }, consumeChunk: { _, data in received.append(data) })
        } catch SSDCheckpointReadBudget.Exhausted.bytes { failed = true }
        #expect(failed == (missingBytes == 1))
        #expect(received == chunks)
        #expect(budget.consumedBytes == ceiling)
        #expect(try Data(contentsOf: file).count == fileBytes)
    }
}
