// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("SSD prefix cache: ready write failure barriers", .serialized)
struct SSDReadyWriteBarrierTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
        func waitForCount(_ expected: Int, timeout: Duration = .seconds(5)) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if count >= expected { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return count >= expected
        }
    }

    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PrefixCacheDonationOutcome] = []

        func set(_ outcome: PrefixCacheDonationOutcome) {
            lock.withLock { values.append(outcome) }
        }

        var outcome: PrefixCacheDonationOutcome? {
            lock.withLock { values.last }
        }

        var count: Int {
            lock.withLock { values.count }
        }
    }

    private enum InjectedWriteError: Error { case failed }

    private func block(_ byte: UInt8) -> SSDBlockWrite {
        let tag = Data(repeating: byte, count: 16)
        return SSDBlockWrite(
            tag16: tag,
            tag16Hex: SSDLookupKeys.hex(tag),
            metadata: SSDBlockMetadata(
                lookupTag: String(repeating: "ab", count: 32),
                weightHash: "w",
                layoutEpoch: "layout",
                blockSize: 8,
                layerCount: 1,
                chunks: [],
                chunkPlaintextSizes: [],
                createdAt: 10_000),
            chunks: [],
            plaintextBytes: 1)
    }

    private func pipeline(
        dir: URL,
        maxJobs: Int = 2,
        volumeSpace: @escaping @Sendable () -> (free: Int, capacity: Int)? = { nil },
        writeBlock: (@Sendable (SSDBlockWrite, URL) throws -> Int)? = nil,
        onBlockSettled: @escaping @Sendable (Data) -> Void = { _ in }
    ) -> SSDWriteBehind {
        SSDWriteBehind(
            config: .init(
                root: dir,
                kekKey: SymmetricKey(size: .bits256),
                strictFsync: false,
                ttlSeconds: 0,
                maxJobs: maxJobs,
                maxQueuedBytes: 1 << 20,
                diskBudgetBytes: { 1 << 20 },
                volumeSpace: volumeSpace,
                nowSeconds: { 10_000 },
                maintainWholeRoot: nil,
                writeBlock: writeBlock),
            rateLimiter: SSDWriteRateLimiter(capBytesPerDay: 0),
            index: SSDBlockIndex(),
            diskBudget: SSDDiskBudget(),
            stats: SSDPrefixCacheStatsBox(),
            onBlockSettled: onBlockSettled,
            sweepExpired: {})
    }

    @Test("low disk, generic write error, ENOSPC, and shutdown never cross durable barrier")
    func failureMatrix() async throws {
        let dir = tempDir("ready-write-failures")
        defer { try? FileManager.default.removeItem(at: dir) }

        let lowCounter = Counter()
        let lowSettled = Counter()
        let lowOutcome = OutcomeBox()
        let low = pipeline(
            dir: dir,
            volumeSpace: { (free: 0, capacity: 1) },
            onBlockSettled: { _ in lowSettled.increment() })
        #expect(low.submit(.init(
            blocks: [block(1)], totalBytes: 1,
            onDurable: { lowCounter.increment(); return true },
            onOutcome: lowOutcome.set)))
        #expect(await lowSettled.waitForCount(1))
        low.close()
        await low.waitUntilDrained()
        #expect(lowCounter.count == 0)
        #expect(lowOutcome.outcome == .diskUnavailable)

        let errorCounter = Counter()
        let errorSettled = Counter()
        let errorOutcome = OutcomeBox()
        let generic = pipeline(
            dir: dir,
            writeBlock: { _, _ in throw InjectedWriteError.failed },
            onBlockSettled: { _ in errorSettled.increment() })
        #expect(generic.submit(.init(
            blocks: [block(2)], totalBytes: 1,
            onDurable: { errorCounter.increment(); return true },
            onOutcome: errorOutcome.set)))
        #expect(await errorSettled.waitForCount(1))
        generic.close()
        await generic.waitUntilDrained()
        #expect(errorCounter.count == 0)
        #expect(errorOutcome.outcome == .writeFailed)

        let enospcCounter = Counter()
        let enospcSettled = Counter()
        let enospcOutcome = OutcomeBox()
        let enospc = pipeline(
            dir: dir,
            writeBlock: { _, _ in throw POSIXError(.ENOSPC) },
            onBlockSettled: { _ in enospcSettled.increment() })
        #expect(enospc.submit(.init(
            blocks: [block(3)], totalBytes: 1,
            onDurable: { enospcCounter.increment(); return true },
            onOutcome: enospcOutcome.set)))
        #expect(await enospcSettled.waitForCount(1))
        enospc.close()
        await enospc.waitUntilDrained()
        #expect(enospcCounter.count == 0)
        #expect(enospcOutcome.outcome == .diskUnavailable)

        let closedCounter = Counter()
        let closed = pipeline(dir: dir)
        closed.close()
        #expect(closed.submitWithResult(.init(
            blocks: [block(4)], totalBytes: 1,
            onDurable: { closedCounter.increment(); return true })) == .closed)
        #expect(closedCounter.count == 0)
    }

    @Test("in-flight close classifies correlated and uncorrelated durable writes as cache_closed")
    func inFlightCloseOutcome() async throws {
        for correlated in [false, true] {
            let dir = tempDir("inflight-close-\(correlated)")
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let settled = Counter()
            let readyAttempted = Counter()
            let outcome = OutcomeBox()
            let writer = pipeline(
                dir: dir,
                writeBlock: { _, _ in
                    entered.signal()
                    _ = release.wait(timeout: .now() + 5)
                    return 1
                },
                onBlockSettled: { _ in settled.increment() })
            let onDurable: (@Sendable () -> Bool)?
            if correlated {
                onDurable = { @Sendable in
                    readyAttempted.increment()
                    return false
                }
            } else {
                onDurable = nil
            }

            #expect(writer.submit(.init(
                blocks: [block(correlated ? 0xA1 : 0xB2)],
                totalBytes: 1,
                onDurable: onDurable,
                onOutcome: outcome.set)))
            #expect(await waitForSemaphore(entered, timeout: .now() + 5) == .success)
            writer.close()
            release.signal()
            await writer.waitUntilDrained()

            #expect(settled.count == 1)
            #expect(readyAttempted.count == (correlated ? 1 : 0))
            #expect(outcome.outcome == .cacheClosed)
            #expect(outcome.count == 1)
            try? FileManager.default.removeItem(at: dir)
        }

        let failedDir = tempDir("inflight-close-write-failure")
        let failedEntered = DispatchSemaphore(value: 0)
        let failedRelease = DispatchSemaphore(value: 0)
        let failedOutcome = OutcomeBox()
        let failedWriter = pipeline(
            dir: failedDir,
            writeBlock: { _, _ in
                failedEntered.signal()
                _ = failedRelease.wait(timeout: .now() + 5)
                throw InjectedWriteError.failed
            })
        #expect(failedWriter.submit(.init(
            blocks: [block(0xC3)],
            totalBytes: 1,
            onOutcome: failedOutcome.set)))
        #expect(await waitForSemaphore(failedEntered, timeout: .now() + 5) == .success)
        failedWriter.close()
        failedRelease.signal()
        await failedWriter.waitUntilDrained()
        #expect(failedOutcome.outcome == .writeFailed)
        #expect(failedOutcome.count == 1)
        try? FileManager.default.removeItem(at: failedDir)
    }

    @Test("queue overflow drops the new receipt job without blocking")
    func queueDrop() async throws {
        let dir = tempDir("ready-queue-drop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let settled = Counter()
        let pipeline = pipeline(dir: dir, maxJobs: 1, writeBlock: { block, _ in
            if block.tag16.first == 1 {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            }
            return 1
        }, onBlockSettled: { _ in settled.increment() })
        defer { release.signal(); pipeline.close() }
        #expect(pipeline.submit(.init(blocks: [block(1)], totalBytes: 1)))
        let enteredResult = await waitForSemaphore(entered, timeout: .now() + 5)
        #expect(enteredResult == .success)
        #expect(pipeline.submit(.init(blocks: [block(2)], totalBytes: 1)))
        let dropped = Counter()
        #expect(pipeline.submitWithResult(.init(
            blocks: [block(3)], totalBytes: 1,
            onDurable: { dropped.increment(); return true })) == .queueFull)
        #expect(dropped.count == 0)
        release.signal()
        #expect(await settled.waitForCount(2))
        pipeline.close()
        await pipeline.waitUntilDrained()
    }
}
