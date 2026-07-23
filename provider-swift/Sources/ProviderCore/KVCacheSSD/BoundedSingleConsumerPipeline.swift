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
// A small `AsyncStream` (buffering policy `.bufferingOldest(capacity)`)
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
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var accepted = 0
        private var dropped = 0
        private var pending = 0
        private var drainWaiters: [CheckedContinuation<Void, Never>] = []

        var acceptedCount: Int { lock.withLock { accepted } }
        var droppedCount: Int { lock.withLock { dropped } }

        func beginSubmit() {
            lock.withLock { pending += 1 }
        }

        func markAccepted() {
            lock.withLock { accepted += 1 }
        }

        func markDropped() {
            lock.withLock { dropped += 1 }
        }

        func completeOne() {
            let waiters = lock.withLock {
                precondition(pending > 0)
                pending -= 1
                guard pending == 0 else {
                    return [CheckedContinuation<Void, Never>]()
                }
                let waiters = drainWaiters
                drainWaiters.removeAll(keepingCapacity: true)
                return waiters
            }
            for waiter in waiters {
                waiter.resume()
            }
        }

        func waitUntilDrained() async {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock {
                    guard pending > 0 else { return true }
                    drainWaiters.append(continuation)
                    return false
                }
                if resumeImmediately {
                    continuation.resume()
                }
            }
        }
    }

    /// Maximum number of payloads buffered before the surplus is dropped.
    let capacity: Int

    private let continuation: AsyncStream<Payload>.Continuation
    private let consumer: Task<Void, Never>
    private let state: State

    /// - Parameters:
    ///   - capacity: max buffered payloads (clamped to ≥ 1). Small by
    ///     design: this is the hard cap on live payloads retained in flight.
    ///   - consume: the (async) sink. Invoked serially by the single
    ///     consumer Task, one payload at a time.
    init(
        capacity: Int,
        onDropped: (@Sendable (Payload) -> Void)? = nil,
        consume: @escaping @Sendable (Payload) async -> Void
    ) {
        let cap = max(1, capacity)
        self.capacity = cap
        let (stream, continuation) = AsyncStream.makeStream(
            of: Payload.self,
            bufferingPolicy: .bufferingOldest(cap)
        )
        let state = State()
        self.continuation = continuation
        self.state = state
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
                if !Task.isCancelled {
                    await consume(payload)
                } else {
                    onDropped?(payload)
                }
                state.completeOne()
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
        state.beginSubmit()
        switch continuation.yield(payload) {
        case .enqueued:
            state.markAccepted()
            return true
        case .dropped:
            // `.bufferingOldest` preserves accepted FIFO work and drops this
            // surplus payload. This is required by callers that settle the
            // returned payload's ownership when submit returns false.
            state.markDropped()
            state.completeOne()
            return false
        case .terminated:
            state.completeOne()
            return false
        @unknown default:
            state.completeOne()
            return false
        }
    }

    /// Count of `submit` calls that buffered without eviction.
    var acceptedCount: Int { state.acceptedCount }
    /// Count of `submit` calls that overflowed the buffer (a payload dropped).
    var droppedCount: Int { state.droppedCount }

    /// Stop accepting, end the consumer loop, and cancel it so an in-flight
    /// `consume` is not awaited indefinitely across teardown. Idempotent.
    /// Releases the stream's buffered payloads.
    func shutdown() {
        continuation.finish()
        consumer.cancel()
    }

    /// Await all work accepted before this call without shutting down the
    /// long-lived consumer. Teardown can call this after `shutdown()` too.
    func waitUntilDrained() async {
        await state.waitUntilDrained()
    }

    deinit {
        // Belt-and-suspenders: if the owner dropped us without `shutdown()`,
        // make sure the stream terminates and the consumer Task ends.
        continuation.finish()
        consumer.cancel()
    }
}
