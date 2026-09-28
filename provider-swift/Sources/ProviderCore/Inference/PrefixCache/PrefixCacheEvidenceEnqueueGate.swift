import Foundation

/// The cache can stop admitting proofs without closing request delivery. Both
/// use the same sequence so a terminal racing shutdown cannot overtake a proof
/// that the finalizer has already enqueued.
final class PrefixCacheEvidenceEnqueueGate: @unchecked Sendable {
    private let lock = NSLock()
    private var nextID: UInt64 = 1
    private var closed = false

    var isOpen: Bool { lock.withLock { !closed } }

    func claim(terminal: Bool) -> UInt64? {
        lock.withLock {
            guard !closed || terminal else { return nil }
            // Wrapping avoids ever exhausting terminal delivery. IDs only need
            // to be unique among pending commands, not over the model lifetime.
            defer { nextID &+= 1 }
            return nextID
        }
    }

    func close() {
        lock.withLock { closed = true }
    }
}

/// Owned by one request's callback rather than the model-wide actor, so duplicate
/// or racing terminal callbacks are suppressed even after that actor deallocates.
final class PrefixCacheTerminalDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
