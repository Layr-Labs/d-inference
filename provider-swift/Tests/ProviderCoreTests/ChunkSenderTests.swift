// Tests for the inference-chunk fast path (ChunkBatcher / ChunkFrameWriter /
// ChunkSender / SendHandle direct path).
//
// Covers the three optimizations and their correctness guarantees:
//   - Throughput: the direct serial-queue path is faster than the
//     AsyncStream control path when the cooperative thread pool is saturated by
//     CPU-bound work (the production MLX-decode contention this work removes).
//   - Coalescing (Opt 2): pending frames are handed to the sink as one batch.
//   - Ordering barrier: a terminal control message (inference_complete) never
//     overtakes queued chunks — SendHandle.send flushes the direct path first.
//   - Reconnect safety: chunks queued with no bound connection are dropped, not
//     resurrected on a later connection.

import Foundation
import Network
import Testing
@testable import ProviderCore

@Suite("ChunkSenderTests", .serialized)
struct ChunkSenderTests {

    // MARK: - Optimization 1: direct path throughput vs AsyncStream

    @Test("direct chunk path is faster than the AsyncStream path under cooperative-pool pressure")
    func directPathBeatsAsyncStreamUnderPressure() async {
        // The whole measurement (including blocking semaphore waits) runs on a
        // dedicated OS thread so the orchestration never occupies a cooperative
        // pool thread — only the CPU hogs and the AsyncStream consumer do, which
        // is the contention we want to measure.
        let result: ThroughputResult = await withCheckedContinuation { cont in
            Thread.detachNewThread {
                cont.resume(returning: Self.runThroughputMeasurement())
            }
        }

        print(String(
            format: "[chunk-throughput] direct=%.3f ms  async=%.3f ms  speedup=%.1fx  (n=%d, cores=%d, directOK=%@, asyncOK=%@)",
            result.directMs, result.asyncMs, result.speedup,
            result.n, result.cores,
            result.directDrained ? "y" : "n", result.asyncDrained ? "y" : "n"))

        #expect(result.directDrained, "direct path did not drain within timeout")
        #expect(result.asyncDrained, "async path did not drain within timeout")
        // The direct path runs on a dedicated serial queue immune to cooperative
        // starvation; the AsyncStream consumer is a Task starved by the hogs.
        let detail = "got \(String(format: "%.1f", result.speedup))x "
            + "(direct=\(String(format: "%.3f", result.directMs))ms async=\(String(format: "%.3f", result.asyncMs))ms)"
        // On real Apple Silicon with MLX saturating the cooperative pool, the
        // direct path is 100-370x faster. On CI runners (limited cores, no MLX)
        // the gap is smaller (~2-5x) because the pool isn't truly starved.
        // Assert >= 1.5x to avoid flaky CI while still catching regressions.
        #expect(result.directMs * 1.5 <= result.asyncMs,
                "direct path should be faster than async; \(detail)")
    }

    struct ThroughputResult: Sendable {
        let directMs: Double
        let asyncMs: Double
        let n: Int
        let cores: Int
        let directDrained: Bool
        let asyncDrained: Bool
        var speedup: Double { directMs > 0 ? asyncMs / directMs : .infinity }
    }

    /// Runs entirely on a dedicated (non-cooperative) thread.
    private static func runThroughputMeasurement() -> ThroughputResult {
        let n = 500
        let cores = max(2, ProcessInfo.processInfo.activeProcessorCount)
        let frame = Data(count: 200) // representative encrypted-chunk size

        // Saturate the cooperative pool: `cores` non-yielding busy loops hold
        // every cooperative thread until a deadline, mirroring MLX decode hogging
        // the pool so the AsyncStream consumer Task cannot be scheduled.
        let stop = TestFlag()
        let deadline = DispatchTime.now() + .milliseconds(900)
        for _ in 0..<cores {
            Task.detached(priority: .userInitiated) {
                var acc = 1.0
                while !stop.get() && DispatchTime.now() < deadline {
                    // Data-dependent math + per-iteration clock read: the compiler
                    // cannot elide it, and it never suspends, so it holds the thread.
                    acc = (acc + 1.000_001).squareRoot() * 1.000_03
                }
                TestSink.shared.store(acc)
            }
        }
        defer { stop.set(true) }
        Thread.sleep(forTimeInterval: 0.06) // let the hogs grab the threads

        // --- Direct path: the REAL ChunkBatcher on its dedicated serial queue ---
        let batcher = ChunkBatcher()
        let directCount = TestCounter()
        let directDone = DispatchSemaphore(value: 0)
        batcher.installSinkForTesting { frames in
            if directCount.add(frames.count) >= n { directDone.signal() }
        }
        let directStart = DispatchTime.now()
        for _ in 0..<n { batcher.enqueue(frame) }
        let directDrained = directDone.wait(timeout: .now() + .seconds(10)) == .success
        let directMs = Self.msSince(directStart)

        // --- AsyncStream path: a cooperative consumer (mirrors sessionLoop Task 2) ---
        let (stream, streamCont) = AsyncStream<Data>.makeStream()
        let asyncCount = TestCounter()
        let asyncDone = DispatchSemaphore(value: 0)
        let consumer = Task.detached(priority: .userInitiated) {
            for await _ in stream {
                if asyncCount.add(1) >= n { asyncDone.signal(); break }
            }
        }
        let asyncStart = DispatchTime.now()
        for _ in 0..<n { streamCont.yield(frame) }
        streamCont.finish()
        let asyncDrained = asyncDone.wait(timeout: .now() + .seconds(30)) == .success
        let asyncMs = Self.msSince(asyncStart)
        consumer.cancel()

        return ThroughputResult(
            directMs: directMs, asyncMs: asyncMs, n: n, cores: cores,
            directDrained: directDrained, asyncDrained: asyncDrained)
    }

    private static func msSince(_ start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
    }

    // MARK: - Optimization 2: coalescing

    @Test("batcher coalesces frames enqueued while the sink is busy into a single batch")
    func batcherCoalescesPendingFramesIntoOneBatch() {
        // Coalescing is best-effort per dispatch turn (see ChunkBatcher.swift
        // header): frames coalesce only if they land in the same turn, so
        // "enqueue 5, expect 1 batch" is timing-dependent — on a loaded runner
        // the deferred flush can run mid-enqueue and split the batch.
        //
        // Deterministic choreography instead: a primer frame's delivery BLOCKS
        // the batcher's serial queue inside the sink (via `gate`). While the
        // queue is blocked, four more frames are enqueued — their enqueue
        // blocks pile up FIFO behind the blocked delivery. Once the gate opens
        // they all append before any flush block can run, so the batcher MUST
        // coalesce them into exactly one batch.
        let batcher = ChunkBatcher()
        let recorder = BatchRecorder()
        let sinkEntered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let primerSeen = TestFlag()

        batcher.installSinkForTesting { frames in
            recorder.record(frames)
            if !primerSeen.get() {
                primerSeen.set(true)
                sinkEntered.signal()
                gate.wait() // hold the serial queue inside the primer delivery
            }
        }

        // Primer: batch 1 is [0], and its delivery parks the queue on `gate`.
        batcher.enqueue(Data([0]))
        guard sinkEntered.wait(timeout: .now() + .seconds(10)) == .success else {
            Issue.record("sink was never invoked for the primer frame")
            gate.signal() // avoid wedging the batcher queue on failure
            return
        }

        // Queue is blocked: these four enqueues are all pending before ANY
        // flush turn can run, so they must drain as one coalesced batch.
        for i in 1..<5 { batcher.enqueue(Data([UInt8(i)])) }
        gate.signal()
        batcher.flush() // sync barrier: everything above is delivered on return

        let batches = recorder.batches()
        #expect(batches.count == 2, "expected primer batch + one coalesced batch, got \(batches.count)")
        #expect(batches.first?.compactMap { $0.first } == [0], "primer batch should be exactly the gated frame")
        #expect(batches.last?.count == 4, "frames enqueued while the sink was busy must coalesce into one batch")
        // Order preserved across and within batches.
        #expect(batches.flatMap { $0 }.compactMap { $0.first } == [0, 1, 2, 3, 4])
    }

    @Test("batcher delivers every frame exactly once across flushes")
    func batcherDeliversEveryFrameExactlyOnce() {
        let batcher = ChunkBatcher()
        let count = TestCounter()
        let done = DispatchSemaphore(value: 0)
        let total = 200
        batcher.installSinkForTesting { frames in
            if count.add(frames.count) >= total { done.signal() }
        }
        for _ in 0..<total { batcher.enqueue(Data(count: 8)) }
        #expect(done.wait(timeout: .now() + .seconds(5)) == .success)
        #expect(count.get() == total)
    }

    // MARK: - Ordering barrier: terminal never overtakes chunks

    @Test("SendHandle flushes queued chunks before a terminal control message")
    func sendHandleFlushesChunksBeforeTerminal() {
        let batcher = ChunkBatcher()
        let order = OrderRecorder()
        batcher.installSinkForTesting { frames in
            order.append("chunkBatch(\(frames.count))")
        }
        let sender = ChunkSender(batcher: batcher, encode: { _ in Data("{}".utf8) })
        let handle = SendHandle({ message in
            if case .inferenceComplete = message { order.append("complete") }
        }, chunkSender: sender)

        for _ in 0..<3 {
            handle.sendChunk(.inferenceChunk(requestId: "r", data: "", encryptedData: nil))
        }
        handle.send(.inferenceComplete(
            requestId: "r",
            usage: UsageInfo(promptTokens: 0, completionTokens: 0),
            seSignature: nil,
            responseHash: nil))

        let events = order.events()
        // The terminal MUST be last: chunks were flushed to the wire first.
        #expect(events.last == "complete", "events: \(events)")
        #expect(events.contains { $0.hasPrefix("chunkBatch") }, "no chunk batch recorded: \(events)")
        let completeIndex = events.firstIndex(of: "complete")
        #expect(completeIndex == events.count - 1, "complete must be the final event; got \(events)")
    }

    @Test("SendHandle without a wired chunk sender falls back to the control path")
    func sendHandleFallsBackToControlPathWhenUnwired() {
        let recorder = OrderRecorder()
        let handle = SendHandle({ message in
            if case .inferenceChunk = message { recorder.append("chunk-control") }
        })
        handle.sendChunk(.inferenceChunk(requestId: "r", data: "", encryptedData: nil))
        #expect(recorder.events() == ["chunk-control"],
                "chunk should route through the control fn when no direct sender is wired")
    }

    // MARK: - Reconnect safety: drop, don't resurrect

    @Test("batcher drops frames enqueued after the connection is unbound")
    func batcherDropsFramesAfterUnbind() {
        let batcher = ChunkBatcher()
        let delivered = TestCounter()
        // A never-started loopback connection; used only for bind/unbind identity.
        let conn = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        batcher.bind(connection: conn) { _ in _ = delivered.add(1) }
        batcher.unbind(ifCurrent: conn)

        batcher.enqueue(Data(count: 16))
        batcher.flush() // would deliver if a sink were still bound
        conn.cancel()

        #expect(delivered.get() == 0, "frames must be dropped after unbind (reconnect window)")
    }

    @Test("unbind(ifCurrent:) does not clobber a newer connection's binding")
    func unbindIgnoresStaleConnection() {
        let batcher = ChunkBatcher()
        let delivered = TestCounter()
        let oldConn = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        let newConn = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)

        // New session binds; the OLD session's teardown must be a no-op.
        batcher.bind(connection: newConn) { _ in _ = delivered.add(1) }
        batcher.unbind(ifCurrent: oldConn)

        batcher.enqueue(Data(count: 16))
        batcher.flush()
        oldConn.cancel()
        newConn.cancel()

        #expect(delivered.get() == 1, "newer binding must survive a stale unbind")
    }
}

// MARK: - Test helpers (file-private, thread-safe)

private final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    @discardableResult
    func add(_ n: Int) -> Int { lock.lock(); defer { lock.unlock() }; value += n; return value }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

private final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set(_ v: Bool) { lock.lock(); flag = v; lock.unlock() }
}

/// Black-hole sink so the busy-loop result is observable (prevents the optimizer
/// from eliding the hog loop).
private final class TestSink: @unchecked Sendable {
    static let shared = TestSink()
    private let lock = NSLock()
    private var value = 0.0
    func store(_ v: Double) { lock.lock(); value = v; lock.unlock() }
}

private final class BatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[Data]] = []
    func record(_ frames: [Data]) { lock.lock(); recorded.append(frames); lock.unlock() }
    func batches() -> [[Data]] { lock.lock(); defer { lock.unlock() }; return recorded }
}

private final class OrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ordered: [String] = []
    func append(_ event: String) { lock.lock(); ordered.append(event); lock.unlock() }
    func events() -> [String] { lock.lock(); defer { lock.unlock() }; return ordered }
}
