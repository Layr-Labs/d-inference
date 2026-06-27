// ChunkFrameWriter: the NWConnection transport for the inference-chunk fast path.
//
// Given a batch of pre-encoded text frames (handed up by ChunkBatcher), it
// writes them to the connection with two micro-optimizations:
//
//   - Optimization 2 (Batching): all sends in the batch are issued inside a
//     single `NWConnection.batch {}` block. Per Apple's Network.framework, this
//     hints the stack to coalesce the sends and "improves performance" by
//     collapsing what would be N separate writes from the same decode step into
//     fewer kernel/TCP operations.
//
//   - Optimization 3 (Pre-allocated send contexts): one
//     `NWProtocolWebSocket.Metadata(opcode: .text)` and one
//     `NWConnection.ContentContext` are created once per session and reused for
//     every chunk, instead of allocating a fresh pair per frame (as the generic
//     `sendTextFrame` control path does). Apple ships reusable static send
//     contexts (`defaultMessage`, `finalMessage`), so reusing a custom text
//     context across sends is supported; here the sends are additionally
//     serialized on ChunkBatcher's queue, so the context is never used
//     concurrently.
//
// One writer is created per WebSocket session (in `connectAndRun`) and captured
// by the batcher's sink closure; it dies with the session.

import Foundation
import Network
#if canImport(os)
import os
#endif

/// Per-session WebSocket text-frame writer with reused send contexts.
///
/// `@unchecked Sendable`: the reused `Metadata`/`ContentContext` are only ever
/// touched on the batcher's serial queue, never concurrently.
final class ChunkFrameWriter: @unchecked Sendable {
    private let connection: NWConnection
    private let logger: CoordinatorWSLogger

    // Opt 3: allocated once, reused for every chunk on this connection.
    private let textMetadata: NWProtocolWebSocket.Metadata
    private let textContext: NWConnection.ContentContext

    init(connection: NWConnection, logger: CoordinatorWSLogger) {
        self.connection = connection
        self.logger = logger
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        self.textMetadata = metadata
        self.textContext = NWConnection.ContentContext(
            identifier: "chunk",
            metadata: [metadata]
        )
    }

    /// Write a batch of frames inside a single `NWConnection.batch {}`.
    /// Fire-and-forget per frame: `NWConnection.send` buffers in the kernel and
    /// returns immediately. On a send error we cancel the connection so the
    /// state handler (sessionLoop Task 0) tears down and the reconnect loop
    /// fires — matching `sendTextFrame`'s failure semantics so the chunk path
    /// and control path fail identically.
    func write(_ frames: [Data]) {
        let connection = self.connection
        let context = self.textContext
        let logger = self.logger
        connection.batch {
            for frame in frames {
                connection.send(
                    content: frame,
                    contentContext: context,
                    isComplete: true,
                    completion: .contentProcessed { error in
                        if let error {
                            logger.error("WS chunk send failed: \(error.localizedDescription)")
                            connection.cancel()
                        }
                    }
                )
            }
        }
    }
}
