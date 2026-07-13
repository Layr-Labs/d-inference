import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Exact syscall boundaries used by durable journal fault tests.
enum JournalFaultPoint: String, Sendable, Hashable {
    case preallocate
    case newFileAllocation
    case write
    case fileSync
    case truncate
    case link
    case rename
    case directorySync
    case unlink
}

struct JournalInjectedSystemFailure: Error, Sendable, Equatable {
    let point: JournalFaultPoint
    let errorNumber: Int32
}

protocol JournalFaultInjecting: Sendable {
    func before(_ point: JournalFaultPoint) throws
}

struct NoJournalFaults: JournalFaultInjecting {
    func before(_: JournalFaultPoint) throws {}
}

/// Test-only-by-convention fault plan. It injects at the real production
/// syscall boundary; encryption, paths, and all non-faulted syscalls remain
/// unchanged.
final class JournalFaultPlan: JournalFaultInjecting, @unchecked Sendable {
    private struct ScheduledFailure {
        var successfulCallsRemaining: Int
        let errorNumber: Int32
    }

    private let lock = NSLock()
    private var failures: [JournalFaultPoint: [ScheduledFailure]] = [:]

    func failNext(_ point: JournalFaultPoint, errno: Int32 = EIO) {
        fail(point, afterSuccessfulCalls: 0, errno: errno)
    }

    func fail(
        _ point: JournalFaultPoint,
        afterSuccessfulCalls: Int,
        errno: Int32 = EIO
    ) {
        precondition(afterSuccessfulCalls >= 0)
        lock.lock()
        failures[point, default: []].append(
            ScheduledFailure(
                successfulCallsRemaining: afterSuccessfulCalls,
                errorNumber: errno
            ))
        lock.unlock()
    }

    func before(_ point: JournalFaultPoint) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var queued = failures[point], !queued.isEmpty else { return }
        if queued[0].successfulCallsRemaining > 0 {
            queued[0].successfulCallsRemaining -= 1
            failures[point] = queued
            return
        }
        let failure = queued.removeFirst()
        failures[point] = queued
        throw JournalInjectedSystemFailure(
            point: point,
            errorNumber: failure.errorNumber
        )
    }
}

/// Advisory OS lock held by its owning journal/store for the object's entire
/// lifetime. A second process or independently-created actor cannot scan a
/// stale snapshot and then over-admit or replace the first actor's records.
final class JournalLifetimeFileLock: @unchecked Sendable {
    private let descriptor: Int32

    init(directory: URL, name: String) throws {
        let path = directory.appendingPathComponent(name).path
        let descriptor = path.withCString {
            open($0, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw TerminalJournalError.systemCall(
                operation: "open lifetime lock",
                errorNumber: errno
            )
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockErrno = errno
            _ = close(descriptor)
            if lockErrno == EWOULDBLOCK || lockErrno == EAGAIN {
                throw TerminalJournalError.lockUnavailable(path)
            }
            throw TerminalJournalError.systemCall(
                operation: "flock lifetime lock",
                errorNumber: lockErrno
            )
        }
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }
}
