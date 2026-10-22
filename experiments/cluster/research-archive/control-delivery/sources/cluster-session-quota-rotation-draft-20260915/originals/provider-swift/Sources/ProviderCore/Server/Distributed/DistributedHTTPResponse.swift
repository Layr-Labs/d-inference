import Foundation

/// A provider-local response handle. It owns no model, lease, or retirement proof.
/// Only the distributed upload responder installs this task-local scope. The
/// bridge copies it before suspension and binds the actual tokenized deadline.
enum DistributedHTTPResponseScope {
    @TaskLocal static var current: DistributedHTTPResponse?
}

final class DistributedHTTPResponse: @unchecked Sendable {
    struct Terminal: Sendable {
        let promptTokens: Int
        let completionTokens: Int
        let cause: InferenceTerminalCause?
    }
    private let lock = NSLock()
    private var bound = false
    private var admissionFinished = false
    private var deadline: ContinuousClock.Instant?
    private var timer: Task<Void, Never>?
    private var cancel: (@Sendable () -> Void)?
    private var expired = false
    private var disconnected = false
    private var completed = false
    private var acceptedContent = false
    private var nativeTerminal: Terminal?
    private let onComplete: @Sendable () -> Void

    init(onComplete: @escaping @Sendable () -> Void = {}) { self.onComplete = onComplete }

    /// Before native admission. An expired budget is a pre-content refusal;
    /// after admission expiry uses normal cancellation and keeps the lease held.
    func bind(deadline: ContinuousClock.Instant?, cancel: @escaping @Sendable () -> Void) throws {
        try lock.withLock {
            guard !bound, !completed, !disconnected else { throw CancellationError() }
            bound = true; self.deadline = deadline; self.cancel = cancel
            if let deadline, ContinuousClock.now >= deadline {
                expired = true
                throw PreContentDeadlineFailure.deadlineUnreachable
            }
            if let deadline {
                timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) }
                    catch { return }
                    self?.expire(at: ContinuousClock.now)
                }
            }
        }
    }

    /// Repeat after synchronous admission: a timer may have fired while no
    /// engine row existed yet. The generation-bound cancel is idempotent.
    func applyPendingCancellation() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            admissionFinished = true
            let action = expired || disconnected ? cancel : nil
            if completed { cancel = nil }
            return action
        }
        action?()
    }

    func expire(at now: ContinuousClock.Instant) {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !completed, !acceptedContent, !expired, let deadline, now >= deadline else { return nil }
            expired = true
            return cancel
        }
        action?()
    }

    /// Called AFTER the local writer accepts a nonempty content frame. This is
    /// not evidence that a remote client received it. Equality loses the race.
    @discardableResult func contentAccepted(at now: ContinuousClock.Instant = ContinuousClock.now) -> Bool {
        expire(at: now)
        let result = lock.withLock { () -> (Bool, Task<Void, Never>?) in
            guard !completed, !disconnected, !expired else { return (false, nil) }
            acceptedContent = true
            let task = timer; timer = nil
            return (true, task)
        }
        result.1?.cancel()
        return result.0
    }

    var deadlineExpired: Bool { lock.withLock { expired } }
    var selectedDeadline: ContinuousClock.Instant? { lock.withLock { deadline } }
    var contentMissingAtTerminal: Bool { lock.withLock { deadline != nil && !acceptedContent } }
    var terminal: Terminal? { lock.withLock { nativeTerminal } }
    var isComplete: Bool { lock.withLock { completed } }

    /// Only the bridge's actual .finished event calls this. EOF, cancellation,
    /// body completion and the three-second delivery cutoff never manufacture it.
    func recordTerminal(_ value: Terminal) {
        lock.withLock { if nativeTerminal == nil { nativeTerminal = value } }
    }

    func disconnect() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !completed, !disconnected else { return nil }
            disconnected = true
            return cancel
        }
        action?()
    }

    func finish() {
        let result = lock.withLock { () -> (Bool, Task<Void, Never>?) in
            guard !completed else { return (false, nil) }
            completed = true
            let task = timer; timer = nil
            // A full connection close can finish this HTTP hold between bind
            // and native admission. Keep its weak engine hook for the mandatory
            // post-admission cancellation recheck, even if the first cancel saw
            // no row yet. No model/lease is retained by that hook.
            if admissionFinished || !bound { cancel = nil }
            return (true, task)
        }
        result.1?.cancel()
        if result.0 { onComplete() }
    }
}
