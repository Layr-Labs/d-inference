import Foundation

public final class InferenceCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var output = OutputState.pending

    /// Me first: a Darkbloom request either sends output or gives way to the owner's request, never both, and the
    /// first of `claimOutput()` and `giveWay()` decides it under this lock. The request claims its output right before
    /// its first output frame goes out, so it gives way only before any of its answer has gone out (the coordinator
    /// writes nothing to its client before first content), and a request that is streaming is never touched.
    private enum OutputState { case pending, sent, gaveWay }

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled || Task.isCancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public func checkCancellation() throws {
        if isCancelled {
            throw CancellationError()
        }
    }

    /// The request is about to send its first output frame (content, reasoning or a tool call); called once per
    /// request, never per token. False when it gave way to the owner first: it sends nothing more and ends with the
    /// re-route refusal.
    public func claimOutput() -> Bool {
        lock.withLock {
            guard output != .gaveWay else { return false }
            output = .sent
            return true
        }
    }

    /// Me first: the request gives way to the owner's request unless it has claimed output or was cancelled. When it
    /// gives way it is cancelled too, and true is returned, once.
    public func giveWay() -> Bool {
        lock.withLock {
            guard output == .pending, !cancelled else { return false }
            output = .gaveWay
            cancelled = true
            return true
        }
    }

    /// The request gave way to the owner (`giveWay`) before it sent output.
    public var gaveWay: Bool {
        lock.withLock { output == .gaveWay }
    }
}

public actor InferenceCancellationRegistry {
    private var tokens: [String: InferenceCancellationToken] = [:]

    public init() {}

    @discardableResult
    public func register(requestId: String) -> InferenceCancellationToken {
        let token = InferenceCancellationToken()
        tokens[requestId] = token
        return token
    }

    public func token(for requestId: String) -> InferenceCancellationToken? {
        tokens[requestId]
    }

    @discardableResult
    public func cancel(requestId: String) -> Bool {
        guard let token = tokens.removeValue(forKey: requestId) else {
            return false
        }
        token.cancel()
        return true
    }

    public func finish(requestId: String) {
        tokens.removeValue(forKey: requestId)
    }

    public var activeRequestIds: [String] {
        tokens.keys.sorted()
    }
}
