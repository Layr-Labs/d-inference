// ChunkBatcher: the inference-chunk fast path's coalescing scheduler.
//
// This is the "direct send" engine that bypasses the OutboundRouter →
// AsyncStream → for-await control path for inference response chunks. Chunks
// are the hot path: under concurrent decode the cooperative thread pool that
// drives the AsyncStream consumer (CoordinatorClient.sessionLoop Task 2) is
// starved by CPU-bound MLX work for ~30-40 ms per scheduling turn, which is the
// dominant per-chunk latency. Routing chunks through a dedicated serial
// DispatchQueue keeps them off the cooperative pool entirely, so they leave for
// the kernel immediately.
//
// Responsibilities (kept narrow so it is unit-testable without a socket):
//   - Optimization 1 (Direct Send): own a dedicated serial DispatchQueue; never
//     touch the cooperative pool.
//   - Optimization 2 (Coalescing): accumulate frames that land within one
//     dispatch turn and hand them to the sink as a single batch so the sink can
//     coalesce them into one TCP write (NWConnection.batch{}). Flush early once
//     the pending bytes approach an MSS so a burst never waits a full turn.
//
// The actual transport (NWConnection.batch + reused contexts, Optimization 3)
// lives behind the injected `sink` — `ChunkFrameWriter` in production, a
// recording closure in tests. Decoupling the queue/coalescing from the socket
// is what lets the throughput test exercise the real scheduler deterministically.

import Foundation
import Network
#if canImport(os)
import os
#endif

/// Serial-queue coalescing scheduler for outbound inference chunks.
///
/// All mutable state is touched ONLY on `queue`; the serial executor is the
/// synchronization (no extra lock). `@unchecked Sendable` because that
/// invariant is upheld by construction, not by the type system.
final class ChunkBatcher: @unchecked Sendable {
    /// Flush as soon as the buffered bytes approach one MSS so a burst doesn't
    /// wait a full dispatch turn and so a coalesced write stays inside a single
    /// ~1500-byte Ethernet MTU. Encrypted chunks are ~150-400 bytes, so this
    /// lets a handful coalesce while keeping latency bounded.
    static let flushThresholdBytes = 1400

    private let queue: DispatchQueue

    // Touched only on `queue`.
    private var sink: (@Sendable ([Data]) -> Void)?
    private var boundConnection: NWConnection?
    // Pre-allocate for typical concurrent batch size. Under solo inference
    // this holds 1 element; under B=4 concurrent it may hold up to 4. The
    // array is drained on every dispatch turn so it never grows large, but
    // reserveCapacity avoids reallocation on the first few enqueues.
    private var pending: [Data] = {
        var a = [Data]()
        a.reserveCapacity(8)
        return a
    }()
    private var pendingBytes = 0
    private var flushScheduled = false

    init(label: String = "dev.darkbloom.coordinator.chunks") {
        // A dedicated, non-QoS-pinned serial queue. Deliberately NOT a target
        // of the cooperative pool — that separation is the whole optimization.
        self.queue = DispatchQueue(label: label)
    }

    // MARK: - Connection lifecycle

    /// Bind the live connection's frame sink for THIS session. Called from
    /// `connectAndRun` after the outbound stream is activated. Routed through
    /// `queue` so it is ordered with respect to any in-flight flush.
    func bind(connection: NWConnection, sink: @escaping @Sendable ([Data]) -> Void) {
        queue.async {
            self.boundConnection = connection
            self.sink = sink
        }
    }

    /// Unbind on session teardown, but ONLY if `connection` is still the bound
    /// one — a concurrent reconnect may have already bound a newer connection,
    /// and the old session's `defer` must not clobber it. Drops any frames still
    /// pending: the owning inference requests are cancelled on disconnect
    /// (`cancelAllInflight`), so a queued chunk has nowhere valid to go.
    func unbind(ifCurrent connection: NWConnection) {
        queue.async {
            guard self.boundConnection === connection else { return }
            self.boundConnection = nil
            self.sink = nil
            self.pending.removeAll(keepingCapacity: true)
            self.pendingBytes = 0
        }
    }

    // MARK: - Hot path

    /// Enqueue one pre-encoded text frame for direct delivery. Coalesces with
    /// other frames that land in the same dispatch turn; flushes immediately
    /// once the byte threshold is crossed.
    func enqueue(_ frame: Data) {
        queue.async {
            self.pending.append(frame)
            self.pendingBytes += frame.count
            if self.pendingBytes >= Self.flushThresholdBytes {
                self.flushPendingOnQueue()
            } else if !self.flushScheduled {
                // Defer to the next dispatch turn so concurrent enqueues from
                // other requests at the same decode step accumulate and flush
                // together (one batched write).
                self.flushScheduled = true
                self.queue.async { self.flushPendingOnQueue() }
            }
        }
    }

    /// Synchronously drain everything pending to the sink. Used as an ORDERING
    /// BARRIER before a terminal control message (`inference_complete` /
    /// `inference_error`) is routed through the slower AsyncStream path: the
    /// coordinator drops any chunk that arrives after `inference_complete`
    /// (it `RemovePending`s on complete), so a terminal must never overtake a
    /// chunk on the wire. `queue.sync` guarantees every chunk enqueued before
    /// this call (FIFO on the serial queue) is handed to the sink first.
    ///
    /// Safe from any non-queue thread (the inference task / actor executor); it
    /// is never called from within `queue`, so there is no sync-deadlock.
    func flush() {
        queue.sync { self.flushPendingOnQueue() }
    }

    // MUST run on `queue`.
    private func flushPendingOnQueue() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        guard let sink else {
            // No live session (reconnect window). Drop — see `unbind`.
            pending.removeAll(keepingCapacity: true)
            pendingBytes = 0
            return
        }
        let frames = pending
        pending.removeAll(keepingCapacity: true)
        pendingBytes = 0
        sink(frames)
    }

    // MARK: - Test seam

    /// Install a recording sink without a real connection. Test-only: lets the
    /// throughput/coalescing tests drive the REAL queue + coalescing logic
    /// while observing flushes deterministically. Not used in production.
    func installSinkForTesting(_ sink: @escaping @Sendable ([Data]) -> Void) {
        queue.async { self.sink = sink }
    }
}
