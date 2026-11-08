import Foundation

public final class InferenceCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

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

    /// The request is about to send its first output (content, reasoning or a tool call). False when it gave way to
    /// the owner first: it sends nothing more and ends with the re-route refusal.
    public func claimOutput() -> Bool { true }

    /// Me first: the request gives way to the owner's request unless it has sent output or was cancelled. When it
    /// gives way it is cancelled too, and true is returned.
    public func yieldToOwner() -> Bool { false }

    /// The request gave way to the owner (`yieldToOwner`) before it sent output.
    public var yieldedToOwner: Bool { false }
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
