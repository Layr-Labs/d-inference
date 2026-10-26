// Bounded start of one coordinator connection: TCP, TLS and the WebSocket
// upgrade must reach `.ready` before a deadline.

import Foundation
import Network

enum CoordinatorConnectionHandshake {
    /// Network.framework keeps a connection in `.preparing` for as long as the
    /// peer holds the TLS handshake or the WebSocket upgrade open without
    /// answering; only a TCP connect that never completes ends on its own. The
    /// session's ping and heartbeat timers start after `.ready`, so without
    /// this deadline one stalled handshake strands the reconnect loop until
    /// the process restarts.
    static let defaultTimeout: TimeInterval = 30

    /// Starts `connection` on `queue` and returns once it is `.ready`. A
    /// failure, a cancellation or the deadline throws, and the deadline also
    /// cancels the connection. `onReady` runs on `queue` before this returns,
    /// so the caller can install its post-handshake state handler with no gap.
    static func start(
        _ connection: NWConnection,
        on queue: DispatchQueue,
        timeout: TimeInterval,
        onReady: @escaping @Sendable () -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let pending = PendingHandshake(continuation)
            connection.stateUpdateHandler = { state in
                let result: Result<Void, Error>
                switch state {
                case .ready:
                    result = .success(())
                case .failed(let error), .waiting(let error):
                    // `.waiting` (DNS failure, refused, no route) is surfaced
                    // so the client's own backoff owns the retry.
                    result = .failure(CoordinatorError.connectionClosed(error))
                case .cancelled:
                    result = .failure(CoordinatorError.connectionClosed(NWError.posix(.ECANCELED)))
                default:
                    return
                }
                guard let continuation = pending.take() else { return }
                if case .success = result {
                    onReady()
                } else {
                    connection.stateUpdateHandler = nil
                }
                continuation.resume(with: result)
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak connection] in
                guard let continuation = pending.take() else { return }
                connection?.stateUpdateHandler = nil
                connection?.cancel()
                continuation.resume(throwing: CoordinatorError.handshakeTimeout(seconds: timeout))
            }
        }
    }
}

/// Hands the continuation to exactly one of the state handler and the
/// deadline. A state update already queued when the deadline fires can still
/// be delivered after the handler is cleared.
private final class PendingHandshake: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func take() -> CheckedContinuation<Void, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}
