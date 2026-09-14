import Foundation

/// Held across asynchronous image work as well as completion. A rejected
/// overlapping or reentrant operation never changes the existing claim.
final class LumeMaintenanceUseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false

    func enter() throws {
        try lock.withLock {
            guard !active else { throw LumeImageMaintenanceError.operationInProgress }
            active = true
        }
    }

    func leave() { lock.withLock { active = false } }

    func withActiveClaim<T>(_ action: () throws -> T) throws -> T {
        try lock.withLock {
            guard active else { throw LumeImageMaintenanceError.noActiveOperation }
            return try action()
        }
    }
}
