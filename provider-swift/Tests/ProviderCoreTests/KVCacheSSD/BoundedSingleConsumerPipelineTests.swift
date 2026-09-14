import Foundation
import Testing

@testable import ProviderCore

// Regression tests for the bounded single-consumer pipeline (re-homed in
// v0.7.5 from the deleted legacy engine's `CheckpointCapturePipeline`,
// where it fixed the Gemma-4 Metal live-resource (499000) leak; its live
// consumer is now the SSD prefix-cache tier's `SSDWriteBehind`).
//
// The leak class: an UNBOUNDED `Task { await consume(...) }` spawned per
// payload pins every payload's live buffers until the slow, serialized
// consumer runs it. The pipeline bounds the number of payloads retained in
// flight and drops the surplus. These tests prove the bound holds and that
// overflow is dropped (not queued).

/// Instance-scoped live/peak counter so parallel tests don't share global
/// state. `enter()` on payload construction, `leave()` on deinit.
private final class LiveCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _live = 0
    private var _peak = 0
    func enter() {
        lock.lock()
        _live += 1
        if _live > _peak { _peak = _live }
        lock.unlock()
    }
    func leave() {
        lock.lock(); _live -= 1; lock.unlock()
    }
    var snapshot: (live: Int, peak: Int) {
        lock.lock(); defer { lock.unlock() }; return (_live, _peak)
    }
}

/// A payload that registers its lifetime with a `LiveCounter`. Stands in
/// for a donated KV host buffer — when it is dropped/evicted, ARC frees it
/// and `leave()` runs.
private final class TrackedPayload: @unchecked Sendable {
    let counter: LiveCounter
    init(_ counter: LiveCounter) { self.counter = counter; counter.enter() }
    deinit { counter.leave() }
}

/// A one-shot async latch used to freeze the pipeline's single consumer so
/// the buffer fills (mirrors a write-behind consumer that has fallen behind).
private actor Latch {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if open { c.resume() } else { waiters.append(c) }
        }
    }
    func release() {
        open = true
        let pending = waiters
        waiters.removeAll()
        for c in pending { c.resume() }
    }
}

private actor ConsumptionCounter {
    private var value = 0

    func increment() {
        value += 1
    }

    var snapshot: Int { value }
}

private actor ConsumedValues {
    private var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }

    var snapshot: [Int] { values }
}

@Test
func pipelineWaitUntilDrainedKeepsConsumerReusable() async {
    let consumed = ConsumptionCounter()
    let pipeline = BoundedSingleConsumerPipeline<Int>(capacity: 4) { _ in
        await consumed.increment()
    }

    for value in 0..<4 {
        #expect(pipeline.submit(value))
    }
    await pipeline.waitUntilDrained()
    #expect(await consumed.snapshot == 4)

    #expect(pipeline.submit(4))
    await pipeline.waitUntilDrained()
    #expect(await consumed.snapshot == 5)

    pipeline.shutdown()
    await pipeline.waitUntilDrained()
}

@Test
func pipelineOverflowDropsSubmittingPayloadWithoutEvictingAcceptedWork() async {
    let firstEntered = Latch()
    let releaseFirst = Latch()
    let consumed = ConsumedValues()
    let pipeline = BoundedSingleConsumerPipeline<Int>(capacity: 1) { value in
        await consumed.append(value)
        if value == 1 {
            await firstEntered.release()
            await releaseFirst.wait()
        }
    }

    #expect(pipeline.submit(1))
    await firstEntered.wait()
    #expect(pipeline.submit(2))
    #expect(!pipeline.submit(3))

    await releaseFirst.release()
    await pipeline.waitUntilDrained()
    #expect(await consumed.snapshot == [1, 2])

    pipeline.shutdown()
    await pipeline.waitUntilDrained()
}

@Test
func pipelineBoundsInFlightPayloads() async {
    let cap = 2
    let total = 200
    let counter = LiveCounter()
    let latch = Latch()

    // Consumer blocks on the first payload, so the buffer fills and stays
    // full — the worst case the leak exploited.
    let pipeline = BoundedSingleConsumerPipeline<TrackedPayload>(capacity: cap) { _ in
        await latch.wait()
    }

    // Flood the pipeline. Each payload is built inline and ownership is
    // handed to `submit`, so the only references that survive are the
    // bounded buffer (≤ cap) and the at-most-one payload the consumer holds.
    for _ in 0..<total {
        pipeline.submit(TrackedPayload(counter))
    }

    // Give the consumer scheduling turns to pull one payload and block.
    for _ in 0..<50 { await Task.yield() }

    let s = counter.snapshot
    // The buffer actually filled (test isn't trivially passing)...
    // ...but never beyond the hard bound. Stable retention is buffer (cap) +
    // ≤1 in the consumer = cap+1; during an evicting submit the just-built
    // payload and the one being evicted briefly coexist, so the transient
    // peak is at most cap+2. Either way it is a small constant.
    #expect(s.peak >= cap, "buffer never filled: peak \(s.peak) < cap \(cap)")
    #expect(s.peak <= cap + 2, "peak retained payloads \(s.peak) exceeded cap+2 (\(cap + 2))")
    #expect(s.live <= cap + 1, "live retained payloads \(s.live) exceeded cap+1 (\(cap + 1))")
    // Proves boundedness vs unbounded Task-per-payload behavior, which
    // would have retained all `total` payloads at once.
    #expect(s.peak < total)
    // Overflow path engaged: surplus payloads were dropped, not queued.
    #expect(pipeline.droppedCount > 0, "expected overflow drops, got none")
    #expect(
        pipeline.acceptedCount + pipeline.droppedCount == total,
        "every submit must be accounted for (accepted+dropped == total)")

    // Drain: unblock the consumer, shut down, wait for the consumer to
    // finish. No payload (or consumer Task) should leak.
    await latch.release()
    pipeline.shutdown()
    await pipeline.waitUntilDrained()

    let drained = counter.snapshot
    #expect(drained.live == 0, "payloads leaked after drain: \(drained.live)")
}

@Test
func pipelineDropsBufferedPayloadsOnShutdown() async {
    // `shutdown()` calls `finish()` + `cancel()`. `finish()` alone still
    // lets the stream deliver already-buffered payloads, and an AsyncStream
    // `for await` does NOT observe Task cancellation on its own — so
    // without the in-loop `Task.isCancelled` guard the consumer would keep
    // consuming the buffered remainder after teardown began. This proves
    // the buffered surplus is DROPPED on teardown: only the single
    // in-flight payload runs.
    let cap = 4
    let total = 64
    let counter = LiveCounter()
    let firstEntered = Latch()  // fires once the consumer is inside consume #1
    let release = Latch()  // unblocks that in-flight consume
    let consumeCalls = LiveCounter()  // peak == number of consume invocations

    let pipeline = BoundedSingleConsumerPipeline<TrackedPayload>(capacity: cap) { _ in
        consumeCalls.enter()
        await firstEntered.release()
        await release.wait()
    }

    for _ in 0..<total { pipeline.submit(TrackedPayload(counter)) }

    // Wait until the consumer is actually blocked inside consume() for
    // payload #1, then let the buffer fill behind it.
    await firstEntered.wait()
    for _ in 0..<50 { await Task.yield() }

    // Tear down while the buffer is full and the consumer is mid-consume,
    // then let the in-flight consume return. The loop must observe
    // cancellation and skip the buffered remainder.
    pipeline.shutdown()
    await release.release()
    await pipeline.waitUntilDrained()

    let calls = consumeCalls.snapshot.peak
    #expect(calls == 1, "expected only the in-flight payload to run after shutdown, got \(calls)")
    #expect(counter.snapshot.live == 0, "buffered payloads leaked after shutdown")
}

@Test
func pipelineCapacityFloorIsOne() async {
    // A non-positive capacity must clamp to ≥ 1, never 0 (a 0-buffer
    // stream would drop everything).
    let p = BoundedSingleConsumerPipeline<TrackedPayload>(capacity: 0) { _ in }
    #expect(p.capacity == 1)
    p.shutdown()
}
