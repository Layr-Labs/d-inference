import Foundation
import Dispatch

/// The bound on an installed session's stop waits (its pair's shutdown and
/// each owner's release proof). A stop someone asked for (a drain, a stop) has
/// no bound of its own here: the caller's deadline and each owner's retirement
/// ceiling bound it. A stop nobody asked for (a rank was lost, a request had to
/// be cancelled) bounds every wait by the unrequested-stop allowance, counted
/// from the moment it began: also a wait that a graceful stop had already
/// started, which it wakes.
final class DistributedInstalledStopBound: @unchecked Sendable {
    private let lock = NSLock()
    private let allowanceNanoseconds: UInt64
    private var unrequestedAt: UInt64?
    /// Graceful waits under way, woken when a stop nobody asked for begins.
    private var wakers: [StopBoundResult<Bool>] = []

    init(allowanceNanoseconds: UInt64) { self.allowanceNanoseconds = allowanceNanoseconds }

    /// A stop nobody asked for began at `now`; the first call counts.
    func beginUnrequested(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        let woken = lock.withLock { () -> [StopBoundResult<Bool>] in
            guard unrequestedAt == nil else { return [] }
            unrequestedAt = now
            defer { wakers = [] }
            return wakers
        }
        for waker in woken { waker.set(true) }
    }

    var isUnrequested: Bool { lock.withLock { unrequestedAt != nil } }

    /// When the allowance of a stop nobody asked for ends; nil while every
    /// stop so far was asked for.
    var allowanceEnd: UInt64? {
        lock.withLock { unrequestedAt.map { $0.addingReportingOverflow(allowanceNanoseconds).partialValue } }
    }

    /// `deadline` cut to the allowance's end once a stop nobody asked for
    /// began (never before now).
    func cut(_ deadline: UInt64?, now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> UInt64? {
        guard let end = allowanceEnd.map({ max($0, now) }) else { return deadline }
        return deadline.map { min($0, end) } ?? end
    }

    /// Runs `body` and waits for it until `deadline` (nil: no deadline of its
    /// own) or, once a stop nobody asked for began (before or during the
    /// wait), until the allowance ends. Returns the body's result, or nil when
    /// the wait ended first; a body still running then goes on by itself.
    func wait<T: Sendable>(until deadline: UInt64?, _ body: @escaping @Sendable () async -> T) async -> T? {
        let result = StopBoundResult<T>(), wake = StopBoundResult<Bool>()
        let graceful = lock.withLock { () -> Bool in
            guard unrequestedAt == nil else { return false }
            wakers.append(wake); return true
        }
        Task { result.set(await body()); wake.set(true) }
        if graceful {
            _ = await wake.wait(until: deadline)
            lock.withLock { wakers.removeAll { $0 === wake } }
            if let value = result.value { return value }
            // Woken by a stop nobody asked for, or the deadline passed.
            guard allowanceEnd != nil else { return nil }
        }
        _ = await result.wait(until: cut(deadline))
        return result.value
    }
}

/// One value set once, and its waiters.
final class StopBoundResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock(), group = DispatchGroup()
    private var stored: T?
    init() { group.enter() }
    var value: T? { lock.withLock { stored } }
    func set(_ value: T) {
        if lock.withLock({ () -> Bool in if stored != nil { return false }; stored = value; return true }) { group.leave() }
    }
    /// True when set by `deadline` (nil: no deadline).
    func wait(until deadline: UInt64?) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.group.wait(timeout: deadline.map { .init(uptimeNanoseconds: $0) } ?? .distantFuture) == .success)
            }
        }
    }
}
