import Foundation
import Testing

@testable import ProviderCore

// Regression tests for the Gemma-4 Metal live-resource (499000) leak fix.
//
// The leak was an UNBOUNDED `Task { await mgr.store(...) }` spawned per
// checkpoint boundary: each Task pinned a live per-layer KV snapshot until the
// (slow, serialized) PrefixCacheManager actor ran it, so under load the live
// Metal buffer count climbed to the ceiling. `CheckpointCapturePipeline` bounds
// the number of snapshots retained in flight and drops the surplus. These tests
// prove the bound holds and that overflow is dropped (not queued).

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

/// A payload that registers its lifetime with a `LiveCounter`. Stands in for a
/// `SendableKVCaches` snapshot — when it is dropped/evicted, ARC frees it and
/// `leave()` runs, exactly as releasing a `SendableKVCaches` frees its buffers.
private final class TrackedPayload: @unchecked Sendable {
    let counter: LiveCounter
    init(_ counter: LiveCounter) { self.counter = counter; counter.enter() }
    deinit { counter.leave() }
}

/// A one-shot async latch used to freeze the pipeline's single consumer so the
/// buffer fills (mirrors a PrefixCacheManager actor that has fallen behind).
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

@Test
func capturePipelineBoundsInFlightSnapshots() async {
    let cap = 2
    let total = 200
    let counter = LiveCounter()
    let latch = Latch()

    // Consumer blocks on the first payload, so the buffer fills and stays full —
    // the worst case the leak exploited.
    let pipeline = CheckpointCapturePipeline<TrackedPayload>(capacity: cap) { _ in
        await latch.wait()
    }

    // Flood the pipeline. Each payload is built inline and ownership is handed
    // to `submit`, so the only references that survive are the bounded buffer
    // (≤ cap) and the at-most-one payload the consumer is holding.
    for _ in 0..<total {
        pipeline.submit(TrackedPayload(counter))
    }

    // Give the consumer scheduling turns to pull one payload and block.
    for _ in 0..<50 { await Task.yield() }

    let s = counter.snapshot
    // The buffer actually filled (test isn't trivially passing)...
    // ...but never beyond the hard bound. Stable retention is buffer (cap) +
    // ≤1 in the consumer = cap+1; during an evicting submit the just-built
    // payload and the one being evicted briefly coexist, so the transient peak
    // is at most cap+2. Either way it is a small constant — never unbounded.
    #expect(s.peak >= cap, "buffer never filled: peak \(s.peak) < cap \(cap)")
    #expect(s.peak <= cap + 2, "peak retained snapshots \(s.peak) exceeded cap+2 (\(cap + 2))")
    // Steady state (no submit in flight): buffer + the one held by the consumer.
    #expect(s.live <= cap + 1, "live retained snapshots \(s.live) exceeded cap+1 (\(cap + 1))")
    // Proves boundedness vs the old unbounded Task-per-capture behavior, which
    // would have retained all `total` snapshots at once.
    #expect(s.peak < total)
    // Overflow path engaged: surplus snapshots were dropped, not queued.
    #expect(pipeline.droppedCount > 0, "expected overflow drops, got none")
    #expect(
        pipeline.acceptedCount + pipeline.droppedCount == total,
        "every submit must be accounted for (accepted+dropped == total)")

    // Drain: unblock the consumer, shut down, wait for the consumer to finish.
    // No snapshot (or consumer Task) should leak.
    await latch.release()
    pipeline.shutdown()
    await pipeline.waitUntilDrained()

    let drained = counter.snapshot
    #expect(drained.live == 0, "snapshots leaked after drain: \(drained.live)")
}

@Test
func capturePipelineDropsBufferedCapturesOnShutdown() async {
    // `shutdown()` calls `finish()` + `cancel()`. `finish()` alone still lets the
    // stream deliver already-buffered payloads, and an AsyncStream `for await`
    // does NOT observe Task cancellation on its own — so without the in-loop
    // `Task.isCancelled` guard the consumer would keep `consume`-ing the buffered
    // remainder after a model swap began, storing old-model KV snapshots that pin
    // live Metal buffers. This proves the buffered surplus is DROPPED on
    // teardown: only the single in-flight capture runs.
    let cap = 4
    let total = 64
    let counter = LiveCounter()
    let firstEntered = Latch()   // fires once the consumer is inside consume #1
    let release = Latch()        // unblocks that in-flight consume
    let consumeCalls = LiveCounter()  // peak == number of consume invocations

    let pipeline = CheckpointCapturePipeline<TrackedPayload>(capacity: cap) { _ in
        consumeCalls.enter()
        await firstEntered.release()
        await release.wait()
    }

    for _ in 0..<total { pipeline.submit(TrackedPayload(counter)) }

    // Wait until the consumer is actually blocked inside consume() for payload #1,
    // then let the buffer fill behind it.
    await firstEntered.wait()
    for _ in 0..<50 { await Task.yield() }

    // Tear down while the buffer is full and the consumer is mid-consume, then
    // let the in-flight consume return. The loop must observe cancellation and
    // break BEFORE consuming any buffered payload.
    pipeline.shutdown()
    await release.release()
    await pipeline.waitUntilDrained()

    let calls = consumeCalls.snapshot.peak
    #expect(calls == 1, "expected only the in-flight capture to run after shutdown, got \(calls)")
    #expect(counter.snapshot.live == 0, "buffered snapshots leaked after shutdown")
}

@Test
func capturePipelineCapacityFloorIsOne() async {
    // A non-positive capacity must clamp to ≥ 1, never 0 (a 0-buffer stream
    // would drop everything and never warm the cache).
    let p = CheckpointCapturePipeline<TrackedPayload>(capacity: 0) { _ in }
    #expect(p.capacity == 1)
    p.shutdown()
}

@Test
func captureAdmissionGateThreshold() {
    // Unknown / non-Metal limit (0) must never gate capture.
    #expect(BatchScheduler.captureResourcePressureHigh(numResources: 999_999, resourceLimit: 0) == false)
    // Below the 70% pressure line → allow capture.
    #expect(BatchScheduler.captureResourcePressureHigh(numResources: 69_000, resourceLimit: 100_000) == false)
    // Exactly at the line → allow (strict greater-than).
    #expect(BatchScheduler.captureResourcePressureHigh(numResources: 70_000, resourceLimit: 100_000) == false)
    // Above the line → gate (skip capture, stop feeding the leak).
    #expect(BatchScheduler.captureResourcePressureHigh(numResources: 70_001, resourceLimit: 100_000) == true)
    // Near the real ~499000 ceiling.
    #expect(BatchScheduler.captureResourcePressureHigh(numResources: 400_000, resourceLimit: 499_000) == true)
}

@Test
func captureMaxInFlightIsSmallAndPositive() {
    #expect(BatchScheduler.captureDefaultMaxInFlight == 2)
    #expect(BatchScheduler.captureMaxInFlight() >= 1)
}
