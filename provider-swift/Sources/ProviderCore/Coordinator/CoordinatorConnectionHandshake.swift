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
    /// terminal state or the deadline throws, and the deadline also cancels
    /// the connection. `onReady` runs on `queue` before this returns, so the
    /// caller can install its post-handshake state handler with no gap.
    static func start(
        _ connection: NWConnection,
        on queue: DispatchQueue,
        timeout: TimeInterval,
        onReady: @escaping @Sendable () -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let pending = PendingHandshake(continuation)
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    guard let continuation = pending.take() else { return }
                    onReady()
                    continuation.resume()
                } else if let error = CoordinatorError(terminalState: state) {
                    guard let continuation = pending.take() else { return }
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                }
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

extension CoordinatorError {
    /// The error a terminal state ends the handshake or the session with; nil
    /// while the connection is still preparing or is ready. `.waiting` (DNS
    /// failure, refused, no route) counts as terminal so the client's own
    /// backoff owns the retry, not Network.framework's internal wait.
    init?(terminalState state: NWConnection.State) {
        switch state {
        case .failed(let error), .waiting(let error):
            self = .connectionClosed(error)
        case .cancelled:
            self = .connectionClosed(NWError.posix(.ECANCELED))
        default:
            return nil
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
