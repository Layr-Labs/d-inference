// Copyright © 2026 Eigen Labs.
//
// Bounded, single-consumer delivery pipeline.
//
// Provenance: extracted verbatim (rename only) from the legacy engine's
// `CheckpointCapturePipeline` when v0.7.5 deleted that engine — the class
// was always generic and MLX-free; only its `BatchScheduler` capture
// wiring died with the legacy tier. It exists because of the Gemma-4
// `[metal::malloc] Resource limit (499000) exceeded` class of bug: a
// producer that spawns an unbounded `Task { await consume(...) }` per
// payload pins every payload's live buffers until the (slow, serialized)
// consumer catches up. This pipeline caps the number of payloads retained
// in flight and DROPS the surplus — best-effort delivery, bounded memory,
// the producer is never back-pressured.
//
// v0.7.5 consumer: `SSDWriteBehind` (the SSD prefix-cache tier's
// write-behind queue of extracted host-buffer donations).
//
// A small `AsyncStream` (buffering policy `.bufferingNewest(capacity)`)
// feeds a single long-lived consumer Task. `submit(_:)` is synchronous,
// non-blocking, and `@Sendable`, so it is safe to call from an engine
// queue. At most `capacity` payloads sit in the buffer and the consumer
// holds at most one more while it `await`s, so the pipeline retains at
// most `capacity + 1` payloads — regardless of how far behind the
// consumer falls. (Counting the single payload being handed to `submit`
// during an evicting enqueue, at most `capacity + 2` are live for an
// instant.)

import Foundation

/// Bounded, single-consumer pipeline: `submit` never blocks, overflow is
/// dropped (returned `false`), the consumer runs payloads serially.
final class BoundedSingleConsumerPipeline<Payload: Sendable>: @unchecked Sendable {
    /// Maximum number of payloads buffered before the surplus is dropped.
    let capacity: Int

    private let continuation: AsyncStream<Payload>.Continuation
    private let consumer: Task<Void, Never>

    // Lightweight counters (lock-guarded; read from tests / future telemetry).
    private let statsLock = NSLock()
    private var _accepted = 0
    private var _dropped = 0

    /// - Parameters:
    ///   - capacity: max buffered payloads (clamped to ≥ 1). Small by
    ///     design: this is the hard cap on live payloads retained in flight.
    ///   - consume: the (async) sink. Invoked serially by the single
    ///     consumer Task, one payload at a time.
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
                // Without this guard we would keep consuming stale payloads
                // after teardown began — pinning their live buffers.
                //
                // We `continue` rather than `break`: the buffered remainder
                // must still be pulled so each payload is released as it
                // drains (the retained `continuation` keeps the stream's
                // internal buffer — and anything stranded in it — alive).
                // Skipping `consume` drops the payloads (best-effort); the
                // finished stream then terminates the loop once its buffer
                // empties.
                if Task.isCancelled { continue }
                await consume(payload)
            }
        }
    }

    /// Enqueue a payload. Synchronous, non-blocking, `@Sendable`.
    ///
    /// Returns `true` when the payload was buffered without eviction,
    /// `false` when the buffer was already full (an overflow occurred and
    /// the surplus payload was dropped + released) or the pipeline has been
    /// shut down.
    @discardableResult
    func submit(_ payload: Payload) -> Bool {
        switch continuation.yield(payload) {
        case .enqueued:
            statsLock.lock(); _accepted += 1; statsLock.unlock()
            return true
        case .dropped:
            // `.bufferingNewest` keeps the newest `capacity` payloads and
            // returns the evicted (oldest) one here; letting it go out of
            // scope releases it immediately.
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
    /// `consume` is not awaited indefinitely across teardown. Idempotent.
    /// Releases the stream's buffered payloads.
    func shutdown() {
        continuation.finish()
        consumer.cancel()
    }

    /// Test seam: await the consumer Task draining to completion. Production
    /// teardown does not need to await this (ARC + `finish()` reclaim the
    /// buffered payloads); tests use it to assert no payloads leak.
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
