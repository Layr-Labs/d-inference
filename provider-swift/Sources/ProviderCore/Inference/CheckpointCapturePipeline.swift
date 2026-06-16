// Copyright © 2026 Eigen Labs.
//
// Bounded, single-consumer pipeline for best-effort checkpoint KV capture.
//
// Background — the Gemma-4 `[metal::malloc] Resource limit (499000) exceeded`
// crash. Heterogeneous models (Gemma-4: sliding [8,256] + full [2,512]) use the
// `.checkpoint` prefix-cache tier. At each checkpoint boundary the engine hands
// the provider a freshly-extracted, per-layer KV snapshot (live MLXArrays,
// ≈ layers × 2 Metal buffers). The previous wiring spawned an UNBOUNDED
// `Task { await mgr.store(...) }` per boundary:
//
//     scheduler.onCheckpointCapture = { prefixTokens, length, caches in
//         let box = SendableKVCaches(caches)
//         Task { await mgr.store(...) }   // <-- one detached Task per boundary
//     }
//
// `PrefixCacheManager` is a single actor that serializes `store` behind
// AES-GCM serialize + fsync and against every lookup/materialize. Under
// sustained traffic the actor falls behind, the spawned Tasks queue, and each
// queued Task keeps its live KV snapshot pinned until it runs. The live Metal
// resource COUNT (not bytes/cache) climbs to the `iogpu.rsrc_limit` ceiling
// (~499000) → crash. The mlx/mlx-c "count-aware" cache trims can only reclaim
// CACHED buffers; these snapshots are LIVE, so trimming cannot help and the
// idle-gated `Memory.clearCache()` never fires under load.
//
// This pipeline caps the number of snapshots retained in flight. Capture is
// best-effort cache-warming: when the bounded buffer is full the surplus
// snapshot is DROPPED (and released, freeing its Metal buffers) rather than
// queued. Dropping a snapshot only costs a future cache miss, never
// correctness.

import Foundation
import MLX
import MLXLMCommon

/// One checkpoint capture: the prefix tokens it covers, the checkpoint length,
/// and the boxed per-layer KV snapshot to hand to `PrefixCacheManager.store`.
/// `SendableKVCaches` is the ownership-transfer box; this struct is the
/// production payload for ``CheckpointCapturePipeline``.
struct CheckpointCapture: Sendable {
    let tokens: [Int]
    let length: Int
    let caches: SendableKVCaches
}

/// Bounded, single-consumer delivery pipeline.
///
/// A small `AsyncStream` (buffering policy `.bufferingNewest(capacity)`) feeds a
/// single long-lived consumer Task. `submit(_:)` is synchronous, non-blocking,
/// and `@Sendable`, so it is safe to call from the engine queue inside
/// `Scheduler.onCheckpointCapture`. At most `capacity` payloads sit in the
/// buffer and the consumer holds at most one more while it `await`s, so the
/// pipeline retains at most `capacity + 1` payloads — regardless of how far
/// behind the consumer falls. (Counting the single payload being handed to
/// `submit` during an evicting enqueue, at most `capacity + 2` are live for an
/// instant.) Surplus payloads are dropped (and released) rather than queued —
/// this small constant bound is what caps the live Metal buffer count and
/// fixes the 499000 leak.
///
/// Generic over `Payload` so the bounding/drop/teardown logic is unit-testable
/// without MLX (the production instantiation is `Payload == CheckpointCapture`).
final class CheckpointCapturePipeline<Payload: Sendable>: @unchecked Sendable {
    /// Maximum number of payloads buffered before the surplus is dropped.
    let capacity: Int

    private let continuation: AsyncStream<Payload>.Continuation
    private let consumer: Task<Void, Never>

    // Lightweight counters (lock-guarded; read from tests / future telemetry).
    private let statsLock = NSLock()
    private var _accepted = 0
    private var _dropped = 0

    /// - Parameters:
    ///   - capacity: max buffered payloads (clamped to ≥ 1). Small by design
    ///     (1–2): this is the hard cap on live KV snapshots retained in flight.
    ///   - consume: the (async) sink. Invoked serially by the single consumer
    ///     Task, one payload at a time.
    init(
        capacity: Int,
        consume: @escaping @Sendable (Payload) async -> Void
    ) {
        let cap = max(1, capacity)
        self.capacity = cap
        let (stream, continuation) = AsyncStream.makeStream(
            of: Payload.self,
            bufferingPolicy: .bufferingNewest(cap)
        )
        self.continuation = continuation
        self.consumer = Task {
            for await payload in stream {
                // Honor shutdown before consuming. `shutdown()` calls
                // `finish()` + `cancel()`, but `finish()` still delivers
                // already-buffered payloads to this loop and an AsyncStream
                // `for await` does NOT observe Task cancellation on its own.
                // Without this guard we would `store(...)` old-model KV
                // snapshots after a model swap has begun — pinning large live
                // Metal buffers that must not overlap the next engine.
                //
                // We `continue` rather than `break`: the buffered remainder must
                // still be pulled so each payload is released as it drains (the
                // retained `continuation` keeps the stream's internal buffer —
                // and anything stranded in it — alive). Skipping `consume` drops
                // the captures (best-effort) without storing them; the finished
                // stream then terminates the loop once its buffer empties.
                if Task.isCancelled { continue }
                await consume(payload)
            }
        }
    }

    /// Enqueue a payload. Synchronous, non-blocking, `@Sendable`.
    ///
    /// Returns `true` when the payload was buffered without eviction, `false`
    /// when the buffer was already full (an overflow occurred and the surplus
    /// payload was dropped + released) or the pipeline has been shut down.
    @discardableResult
    func submit(_ payload: Payload) -> Bool {
        switch continuation.yield(payload) {
        case .enqueued:
            statsLock.lock(); _accepted += 1; statsLock.unlock()
            return true
        case .dropped:
            // `.bufferingNewest` keeps the newest `capacity` payloads and
            // returns the evicted (oldest) one here; letting it go out of scope
            // releases its KV snapshot so the Metal buffers free immediately.
            statsLock.lock(); _dropped += 1; statsLock.unlock()
            return false
        case .terminated:
            return false
        @unknown default:
            return false
        }
    }

    /// Count of `submit` calls that buffered without eviction.
    var acceptedCount: Int { statsLock.lock(); defer { statsLock.unlock() }; return _accepted }
    /// Count of `submit` calls that overflowed the buffer (a payload dropped).
    var droppedCount: Int { statsLock.lock(); defer { statsLock.unlock() }; return _dropped }

    /// Stop accepting, end the consumer loop, and cancel it so an in-flight
    /// `consume` is not awaited indefinitely across a model swap. Idempotent.
    /// Releases the stream's buffered payloads (their Metal buffers free).
    func shutdown() {
        continuation.finish()
        consumer.cancel()
    }

    /// Test seam: await the consumer Task draining to completion. Production
    /// teardown does not need to await this (ARC + `finish()` reclaim the
    /// buffered snapshots); tests use it to assert no payloads leak.
    func waitUntilDrained() async {
        await consumer.value
    }

    deinit {
        // Belt-and-suspenders: if the owner dropped us without `shutdown()`,
        // make sure the stream terminates and the consumer Task ends.
        continuation.finish()
        consumer.cancel()
    }
}

// MARK: - BatchScheduler capture wiring

extension BatchScheduler {
    /// Fraction of `Memory.resourceLimit` above which checkpoint capture is
    /// skipped. Matches the submodule's `[rsrc]` pressure threshold (70%).
    static let captureResourcePressureFraction = 0.7

    /// Default cap on KV snapshots retained in flight. Intentionally tiny:
    /// capture is best-effort, and the whole point is to bound live buffers.
    static let captureDefaultMaxInFlight = 2

    /// Resolve the in-flight cap. Env-tunable via
    /// `DARKBLOOM_KV_CAPTURE_MAX_INFLIGHT` (clamped to ≥ 1).
    static func captureMaxInFlight() -> Int {
        let raw = ProcessInfo.processInfo.environment["DARKBLOOM_KV_CAPTURE_MAX_INFLIGHT"]?
            .trimmingCharacters(in: .whitespaces)
        if let raw, let n = Int(raw), n >= 1 { return n }
        return captureDefaultMaxInFlight
    }

    /// Pure decision (testable): is the live Metal buffer count high enough that
    /// we should skip capture and stop feeding the leak? An unknown limit (0 —
    /// non-Metal backend / unset sysctl) is treated as "no pressure" so capture
    /// is never disabled spuriously.
    static func captureResourcePressureHigh(numResources: Int, resourceLimit: Int) -> Bool {
        guard resourceLimit > 0 else { return false }
        return Double(numResources) > captureResourcePressureFraction * Double(resourceLimit)
    }

    /// Live reading of the above against the MLX allocator counters.
    static func captureResourcePressureHigh() -> Bool {
        captureResourcePressureHigh(
            numResources: MLX.Memory.numResources,
            resourceLimit: MLX.Memory.resourceLimit
        )
    }

    /// The `onCheckpointCapture` hook type the engine's `Scheduler` exposes.
    typealias CheckpointCaptureHook =
        @Sendable (_ prefixTokens: [Int], _ checkpointLength: Int, _ caches: [any KVCache]) -> Void

    /// Build the bounded capture pipeline + the synchronous `@Sendable` hook for
    /// a checkpoint-tier manager. Shared by the production engine builder and the
    /// test seam so both get identical backpressure + admission-gating.
    ///
    /// The hook does two things, both cheap and non-blocking:
    ///   1. Admission gate — skip (and release) the snapshot when the live Metal
    ///      buffer count is already high; that is exactly when feeding more
    ///      snapshots risks the 499000 ceiling.
    ///   2. Backpressure — submit to the bounded pipeline, which drops on full.
    static func makeCheckpointCaptureWiring(
        manager mgr: PrefixCacheManager
    ) -> (pipeline: CheckpointCapturePipeline<CheckpointCapture>, hook: CheckpointCaptureHook) {
        let maxInFlight = captureMaxInFlight()
        let pipeline = CheckpointCapturePipeline<CheckpointCapture>(
            capacity: maxInFlight
        ) { capture in
            // TB-016 sub-feature B: capture = RAM-ONLY. The 2nd-use promotion in
            // the manager handles SSD persistence; no eager flushToSSD here.
            await mgr.store(
                tokens: capture.tokens,
                checkpointLength: capture.length,
                caches: capture.caches
            )
        }
        prefixCacheLogger.info(
            "checkpoint capture pipeline: max-in-flight \(maxInFlight) (drop-on-full), admission-gate at \(Int(captureResourcePressureFraction * 100))% of Metal resource limit")
        let hook: CheckpointCaptureHook = { [pipeline] prefixTokens, length, caches in
            // 1. Admission gate. Returning here lets the `caches` argument go
            //    out of scope → its Metal buffers free immediately.
            if captureResourcePressureHigh() { return }
            // Bounded, single-consumer, drop-on-full backpressure. Caps the live
            // KV snapshots retained while the manager actor is busy with
            // crypto + fsync, regardless of how far behind it falls.
            pipeline.submit(
                CheckpointCapture(
                    tokens: prefixTokens,
                    length: length,
                    caches: SendableKVCaches(caches)
                )
            )
        }
        return (pipeline, hook)
    }
}
