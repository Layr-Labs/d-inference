import Foundation

/// Bounds actual uncancellable DeviceCheck operations, not just Swift waiters.
/// Timeout/cancellation may finish a waiter, but only Apple's callback releases
/// the operation. A duplicate late callback cannot release a newer operation.
final class AppleOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active: UUID?

    func acquire() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard active == nil else { return nil }
        let token = UUID()
        active = token
        return token
    }

    func finish(_ token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if active == token { active = nil }
    }
}
