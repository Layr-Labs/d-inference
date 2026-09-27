import Foundation

/// Bounds actual uncancellable DeviceCheck operations, not just Swift waiters.
/// Timeout/cancellation may finish a waiter, but only Apple's callback releases
/// the operation. A duplicate late callback cannot release a newer operation.
/// The acquisition time lets callers report an Apple call that never answers.
final class AppleOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var active: (token: UUID, since: Date)?

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    func acquire() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard active == nil else { return nil }
        let token = UUID()
        active = (token, now())
        return token
    }

    func finish(_ token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if active?.token == token { active = nil }
    }

    /// When the outstanding Apple operation was admitted, or nil when idle.
    var heldSince: Date? {
        lock.lock()
        defer { lock.unlock() }
        return active?.since
    }
}
