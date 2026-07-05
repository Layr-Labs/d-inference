// OutboundRouter: per-connection outbound delivery. Buffers provider->coordinator
// messages and hands them to the active connection's AsyncStream continuation.

import Foundation
import Network
#if canImport(os)
import os
#endif

// MARK: - OutboundRouter (per-connection outbound delivery)

/// Routes outbound messages to the *current* connection's stream.
///
/// The stable `send` closure handed to callers (ProviderLoop) routes through
/// this so it always reaches the live session. Crucially, the outbound
/// `AsyncStream` is recreated for every connection: an `AsyncStream` is
/// single-shot, so once a session's consuming task is cancelled on disconnect
/// its iterator is permanently terminated. Reusing one stream across reconnects
/// silently dropped every outbound message -- including attestation challenge
/// responses -- after the first reconnect, leaving providers stuck
/// `hardware/untrusted reason=timeout` on an otherwise-healthy connection
/// (heartbeats and ping/pong run on separate tasks, so the socket stayed up).
///
/// A lock (matching PongTracker/ManagedAtomic) is used instead of actor
/// isolation so `send` can stay a synchronous, non-async closure.
internal final class OutboundRouter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var continuation: AsyncStream<OutboundMessage>.Continuation?

    /// Install the continuation for a new connection, finishing any prior one.
    func activate(_ cont: AsyncStream<OutboundMessage>.Continuation) {
        let previous: AsyncStream<OutboundMessage>.Continuation? = lock.withLock {
            let prev = continuation
            continuation = cont
            return prev
        }
        previous?.finish()
    }

    /// Yield a message to the current connection, if any. Messages produced
    /// while disconnected are dropped (the caller cannot reach the coordinator
    /// anyway) rather than buffered into a stream nothing is consuming.
    func yield(_ msg: OutboundMessage) {
        let cont = lock.withLock { continuation }
        cont?.yield(msg)
    }

    /// Tear down outbound delivery permanently (shutdown).
    func finish() {
        let cont: AsyncStream<OutboundMessage>.Continuation? = lock.withLock {
            let c = continuation
            continuation = nil
            return c
        }
        cont?.finish()
    }
}

