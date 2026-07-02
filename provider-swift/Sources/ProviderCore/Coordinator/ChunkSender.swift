// ChunkSender: Sendable, actor-free façade over ChunkBatcher for the inference
// hot path.
//
// `ProviderLoop`'s `emitSSE` closure runs on a detached, `@Sendable` inference
// task. It must reach the WebSocket WITHOUT hopping back onto an actor (the
// CoordinatorClient actor hop + AsyncStream consumer scheduling is exactly the
// latency this work removes). ChunkSender is the captured handle that does the
// nonisolated encode + enqueue.
//
// Encoding (`CoordinatorClientCodec.encodeOutboundMessage`) is a pure static
// codec — already nonisolated in the existing design — so it runs inline on
// the inference task. The encoder's Data output is handed straight to the
// batcher's serial queue for direct delivery (no Data -> String -> Data round
// trip on the per-token path; WebSocket text frames carry raw UTF-8 bytes).

import Foundation

/// Hot-path sender for inference chunks. Wraps a `ChunkBatcher` plus the pure
/// encode step. `@unchecked Sendable` (it only forwards into the Sendable
/// batcher and an injected `@Sendable` encoder; it holds no mutable state).
final class ChunkSender: @unchecked Sendable {
    private let batcher: ChunkBatcher
    private let encode: @Sendable (OutboundMessage) -> Data?

    init(batcher: ChunkBatcher, encode: @escaping @Sendable (OutboundMessage) -> Data?) {
        self.batcher = batcher
        self.encode = encode
    }

    /// Encode an inference chunk and enqueue it for direct delivery. Returns
    /// `false` only when encoding fails, so the caller can fall back to the
    /// control path; a successful encode always "succeeds" even if no live
    /// connection is bound (the batcher drops it — the request is being torn
    /// down on disconnect, so a dropped chunk is correct, never resurrected on a
    /// later connection).
    @discardableResult
    func sendChunk(_ message: OutboundMessage) -> Bool {
        guard let frame = encode(message) else { return false }
        batcher.enqueue(frame)
        return true
    }

    /// Ordering barrier: synchronously drain queued chunks before a terminal
    /// control message is sent through the (slower) AsyncStream path. See
    /// `ChunkBatcher.flush()`.
    func flush() {
        batcher.flush()
    }
}
