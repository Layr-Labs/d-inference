import Foundation

/// Calibration has lower priority than every serving request on this Mac.
/// A foreground lease blocks new probes through preparation/admission; an
/// existing probe must finish its native retirement before the lease returns.
///
/// The wait for that retirement is bounded and ends with the waiting request.
/// A probe whose engine stops stepping never retires, and an unbounded wait
/// that ignored cancellation held every later request on the Mac behind it:
/// accepted, never started, never ended by its coordinator's cancel.
final class IdleCalibrationCoordinator: @unchecked Sendable {
    /// What a foreground request may do after preempting the session.
    enum ForegroundAdmission {
        /// The session retired, or none was running: admission may proceed.
        case admitted(IdleCalibrationForegroundLease)
        /// The waiting request was cancelled first. Nothing was admitted.
        case cancelled
        /// The session did not retire within the bound. Nothing was admitted;
        /// the session stays overdue until it retires (`isOverdue`).
        case retirementOverdue
    }

    private let lock = NSLock()
    private var foreground = Set<UUID>()
    private var session: (id: UUID, task: Task<Void, Never>, toleratesPrefixStoreTransfers: Bool)?
    /// First cancellation of the current session, for its outcome log.
    private var cancelledBy: String?
    /// Requests waiting for the current session to retire.
    private var retirementWaiters: [UUID: RetirementWait] = [:]
    /// The current session outlived a waiting request's bound.
    private var overdueSession: UUID?
    private var bound: Duration = .seconds(30)

    /// How long a request waits for a preempted session to retire. A cancelled
    /// probe retires at its engine's next step, and its cells are bounded at
    /// `ModelCalibrationPolicy.maximumGroupSeconds`; a session still running
    /// past this has stopped making progress.
    var retirementBound: Duration {
        get { lock.withLock { bound } }
        set { lock.withLock { bound = newValue } }
    }

    /// - Parameter toleratesPrefixStoreTransfers: the session is a hidden
    ///   request that restores from and writes to the prefix store itself, so
    ///   that store's device transfers do not end it. Everything else does.
    func startIfIdle(isIdle: () -> Bool,
        toleratesPrefixStoreTransfers: Bool = false,
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
            session = (id, task, toleratesPrefixStoreTransfers)
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

    /// Preempts the running session and waits for its retirement, at most
    /// `retirementBound`, and only while the calling task is not cancelled.
    /// The lease blocks new sessions until it finishes; a refusal holds none.
    func admitForeground() async -> ForegroundAdmission {
        let id = UUID()
        let wait = RetirementWait()
        let (task, bound) = lock.withLock { () -> (Task<Void, Never>?, Duration) in
            foreground.insert(id)
            guard let session else { return (nil, self.bound) }
            if cancelledBy == nil { cancelledBy = "request" }
            retirementWaiters[id] = wait
            return (session.task, self.bound)
        }
        let lease = IdleCalibrationForegroundLease { [self] in
            _ = lock.withLock { foreground.remove(id) }
        }
        guard let task else { return .admitted(lease) }
        task.cancel()
        let timer = Task {
            try? await Task.sleep(for: bound)
            wait.resolve(.overdue)
        }
        let outcome = await withTaskCancellationHandler {
            await wait.outcome()
        } onCancel: {
            wait.resolve(.cancelled)
        }
        timer.cancel()
        lock.withLock {
            retirementWaiters[id] = nil
            if outcome == .overdue, let session { overdueSession = session.id }
        }
        switch outcome {
        case .retired:
            return .admitted(lease)
        case .cancelled:
            lease.finish()
            return .cancelled
        case .overdue:
            lease.finish()
            return .retirementOverdue
        }
    }

    /// Device work ends the session. A prefix-store transfer does not end a
    /// session that tolerates them; it is not that session's canceller.
    func cancel(prefixStoreTransfer: Bool = false) {
        let task = lock.withLock { () -> Task<Void, Never>? in
            guard let session, !(prefixStoreTransfer && session.toleratesPrefixStoreTransfers) else {
                return nil
            }
            if cancelledBy == nil { cancelledBy = "device work" }
            return session.task
        }
        task?.cancel()
    }

    /// A calibration or shape-warmup session currently owns the idle Mac.
    var hasSession: Bool { lock.withLock { session != nil } }
    var cancellationSource: String? { lock.withLock { cancelledBy } }

    /// Whether `task` is the current session and it outlived a waiting
    /// request's bound. Cleared when it retires.
    func isOverdue(_ task: Task<Void, Never>?) -> Bool {
        guard let task else { return false }
        return lock.withLock {
            guard let session, session.task == task else { return false }
            return overdueSession == session.id
        }
    }

    private func finish(_ id: UUID) {
        let waiters = lock.withLock { () -> [RetirementWait] in
            guard session?.id == id else { return [] }
            session = nil
            overdueSession = nil
            defer { retirementWaiters.removeAll() }
            return Array(retirementWaiters.values)
        }
        for waiter in waiters { waiter.resolve(.retired) }
    }
}

/// One waiting request's outcome: the first of retirement, its bound, or its
/// cancellation.
private final class RetirementWait: @unchecked Sendable {
    enum Outcome { case retired, overdue, cancelled }

    private let lock = NSLock()
    private var result: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?

    func outcome() async -> Outcome {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Outcome? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func resolve(_ outcome: Outcome) {
        let waiting = lock.withLock { () -> CheckedContinuation<Outcome, Never>? in
            guard result == nil else { return nil }
            result = outcome
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: outcome)
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
