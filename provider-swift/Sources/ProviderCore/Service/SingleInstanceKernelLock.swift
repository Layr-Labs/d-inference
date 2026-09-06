import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Lifetime-held advisory lock on a stable sidecar inode.
///
/// The owner record itself is atomically replaced, so locking that path would
/// protect the old inode only. Every contender instead opens
/// `<provider.pid>.lock`, which is never renamed or unlinked.
final class SingleInstanceKernelLock: @unchecked Sendable {
    enum LockError: Error {
        case openFailed(String)
        case lockFailed(String)

        var reason: String {
            switch self {
            case .openFailed(let reason), .lockFailed(let reason):
                return reason
            }
        }
    }

    let path: URL
    private let descriptor: Int32
    private let releaseMutex = NSLock()
    private var released = false

    private init(path: URL, descriptor: Int32) {
        self.path = path
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    static func sidecarPath(for ownerRecord: URL) -> URL {
        ownerRecord.deletingLastPathComponent()
            .appendingPathComponent(ownerRecord.lastPathComponent + ".lock")
    }

    /// Returns nil when another process owns the lock.
    static func tryAcquire(at path: URL) throws -> SingleInstanceKernelLock? {
        let descriptor = open(
            path.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw LockError.openFailed(posixMessage())
        }

        guard fchmod(descriptor, 0o600) == 0 else {
            let reason = posixMessage()
            close(descriptor)
            throw LockError.openFailed(reason)
        }

        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR {
                continue
            }
            close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                return nil
            }
            throw LockError.lockFailed(String(cString: strerror(code)))
        }

        return SingleInstanceKernelLock(path: path, descriptor: descriptor)
    }

    func release() {
        releaseMutex.lock()
        defer { releaseMutex.unlock() }
        guard !released else { return }
        released = true
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    private static func posixMessage() -> String {
        String(cString: strerror(errno))
    }
}

struct HeldSingleInstanceLock {
    let processIdentity: ProcessIdentity
    let kernelLock: SingleInstanceKernelLock
}

/// Serializes same-process callers and retains each descriptor until explicit
/// release. The kernel lock supplies cross-process exclusion.
final class SingleInstanceLockRegistry: @unchecked Sendable {
    static let shared = SingleInstanceLockRegistry()

    private let mutex = NSLock()
    private var heldLocks: [String: HeldSingleInstanceLock] = [:]

    private init() {}

    func synchronized<T>(
        _ body: (inout [String: HeldSingleInstanceLock]) throws -> T
    ) rethrows -> T {
        mutex.lock()
        defer { mutex.unlock() }
        return try body(&heldLocks)
    }
}
