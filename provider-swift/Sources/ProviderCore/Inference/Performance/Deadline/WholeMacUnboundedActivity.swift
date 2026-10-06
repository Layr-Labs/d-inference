import Foundation

/// Device work outside the reviewed text request envelope. This receipt owns
/// only forecast invalidation, never memory or a service allowance. Keep it
/// through synchronous GPU readback and any handoff to an unqualified lease.
final class WholeMacUnboundedActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var release: (@Sendable () -> Void)?

    init(release: @escaping @Sendable () -> Void) {
        self.release = release
    }

    func finish() {
        let callback = lock.withLock {
            defer { release = nil }
            return release
        }
        callback?()
    }

    deinit { finish() }
}
