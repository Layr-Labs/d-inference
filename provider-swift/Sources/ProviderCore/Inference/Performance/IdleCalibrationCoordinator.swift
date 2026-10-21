import Foundation

/// Calibration has lower priority than every serving request on this Mac.
/// A foreground lease blocks new probes through preparation/admission; an
/// existing probe must finish its native retirement before the lease returns.
final class IdleCalibrationCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var foreground = Set<UUID>()
    private var session: (id: UUID, task: Task<Void, Never>)?
    /// First cancellation of the current session, for its outcome log.
    private var cancelledBy: String?

    func startIfIdle(isIdle: () -> Bool,
        onRetired: (@Sendable () async -> Void)? = nil,
        operation: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
        lock.withLock {
            guard foreground.isEmpty, session == nil, isIdle() else { return nil }
            cancelledBy = nil
            let id = UUID()
            let task = Task(priority: .background) {
                await operation()
                self.finish(id)
            }
            session = (id, task)
            // Foreground admission awaits only the session's retirement. Successor
            // scheduling crosses actors, so it runs after the global owner is
            // released without extending a customer request's deadline wait. A
            // preempted session leaves successors to the next idle opportunity.
            if let onRetired {
                Task(priority: .background) {
                    await task.value
                    guard !task.isCancelled else { return }
                    await onRetired()
                }
            }
            return task
        }
    }

    func beginForeground() async -> IdleCalibrationForegroundLease {
        let id = UUID()
        let task = lock.withLock {
            foreground.insert(id)
            if session != nil, cancelledBy == nil { cancelledBy = "request" }
            return session?.task
        }
        task?.cancel()
        await task?.value
        return IdleCalibrationForegroundLease { [self] in
            _ = lock.withLock { foreground.remove(id) }
        }
    }

    func cancel() {
        let task = lock.withLock {
            if session != nil, cancelledBy == nil { cancelledBy = "device work" }
            return session?.task
        }
        task?.cancel()
    }

    /// A calibration or shape-warmup session currently owns the idle Mac.
    var hasSession: Bool { lock.withLock { session != nil } }
    var cancellationSource: String? { lock.withLock { cancelledBy } }

    private func finish(_ id: UUID) {
        lock.withLock { if session?.id == id { session = nil } }
    }
}

/// This lease only blocks new calibration. It is not a device-work or memory
/// receipt and must not affect reviewed deadline posture or service accounting.
final class IdleCalibrationForegroundLease: @unchecked Sendable {
    private let lock = NSLock()
    private var release: (@Sendable () -> Void)?
    init(release: @escaping @Sendable () -> Void) { self.release = release }
    func finish() {
        let callback = lock.withLock {
            defer { release = nil }
            return release
        }
        callback?()
    }
    deinit { finish() }
}
