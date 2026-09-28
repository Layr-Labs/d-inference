import Foundation

/// Local HTTP transport ownership only. Coordinator requests retain their
/// existing explicit cancellation path and have no value in this task local.
enum LocalRequestCancellation {
    @TaskLocal static var current: LocalRequestCancellationScope?
}

/// All mutable state is lock protected; callbacks execute outside the lock.
final class LocalRequestCancellationScope: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var actions: [UUID: @Sendable () -> Void] = [:]
    private let onRelease: @Sendable () -> Void

    init(onRelease: @escaping @Sendable () -> Void = {}) { self.onRelease = onRelease }
    deinit { onRelease() }

    func register(_ action: @escaping @Sendable () -> Void) -> Registration {
        let id = UUID()
        let runNow = lock.withLock {
            if cancelled { return true }
            actions[id] = action
            return false
        }
        if runNow { action() }
        return Registration(scope: self, id: id)
    }

    func cancel() {
        let pending: [@Sendable () -> Void] = lock.withLock {
            guard !cancelled else { return [] }
            cancelled = true
            let pending = Array(actions.values)
            actions.removeAll()
            return pending
        }
        for action in pending { action() }
    }

    var registrationCount: Int { lock.withLock { actions.count } }

    private func remove(_ id: UUID) { lock.withLock { _ = actions.removeValue(forKey: id) } }

    final class Registration: @unchecked Sendable {
        private weak var scope: LocalRequestCancellationScope?
        private let id: UUID
        fileprivate init(scope: LocalRequestCancellationScope, id: UUID) {
            self.scope = scope
            self.id = id
        }
        func remove() { scope?.remove(id) }
        deinit { remove() }
    }
}
