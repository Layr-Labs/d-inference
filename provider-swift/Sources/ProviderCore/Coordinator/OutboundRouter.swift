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
    struct Activation: Sendable, Equatable {
        fileprivate let id: UUID
    }

    enum YieldResult: Sendable, Equatable {
        case enqueued
        case droppedDisconnected
        case droppedBufferFull
        case terminated
    }

    private let lock = OSAllocatedUnfairLock()
    private var active:
        (
            activation: Activation,
            continuation: AsyncStream<OutboundMessage>.Continuation
        )?

    /// Install the continuation for a new connection, finishing any prior one.
    @discardableResult
    func activate(_ cont: AsyncStream<OutboundMessage>.Continuation) -> Activation {
        let activation = Activation(id: UUID())
        let previous: AsyncStream<OutboundMessage>.Continuation? = lock.withLock {
            let previous = active?.continuation
            active = (activation, cont)
            return previous
        }
        previous?.finish()
        return activation
    }

    /// Yield a message to the current connection, if any. Messages produced
    /// while disconnected are dropped (the caller cannot reach the coordinator
    /// anyway) rather than buffered into a stream nothing is consuming.
    @discardableResult
    func yield(_ msg: OutboundMessage) -> YieldResult {
        guard let continuation = lock.withLock({ active?.continuation }) else {
            return .droppedDisconnected
        }
        switch continuation.yield(msg) {
        case .enqueued:
            return .enqueued
        case .dropped:
            return .droppedBufferFull
        case .terminated:
            return .terminated
        @unknown default:
            return .terminated
        }
    }

    /// Detach exactly one completed connection. The identity check prevents an
    /// old connection's defer from clobbering a newly activated reconnect.
    func deactivate(_ activation: Activation) {
        let continuation: AsyncStream<OutboundMessage>.Continuation? = lock.withLock {
            guard active?.activation == activation else { return nil }
            let continuation = active?.continuation
            active = nil
            return continuation
        }
        continuation?.finish()
    }

    /// Tear down outbound delivery permanently (shutdown).
    func finish() {
        let cont: AsyncStream<OutboundMessage>.Continuation? = lock.withLock {
            let continuation = active?.continuation
            active = nil
            return continuation
        }
        cont?.finish()
    }
}
