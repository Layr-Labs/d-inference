import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Cache-wide kernel lease held from the authoritative capacity check through
/// publish. Independent CLI processes therefore cannot both admit against the
/// same free bytes.
final class ModelDownloadCacheAdmissionLock: @unchecked Sendable {
    enum LockError: Error, LocalizedError {
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason):
                "Could not acquire the model-cache download lock: \(reason)"
            }
        }
    }

    private static let fileName = ".darkbloom-download.lock"

    let path: URL
    private let descriptor: Int32
    private let releaseLock = NSLock()
    private var released = false

    private init(path: URL, descriptor: Int32) {
        self.path = path
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    static func acquire(at cacheRoot: URL) async throws -> ModelDownloadCacheAdmissionLock {
        let (path, descriptor) = try openLockFile(at: cacheRoot)

        do {
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                if code == EINTR {
                    continue
                }
                guard code == EWOULDBLOCK || code == EAGAIN else {
                    throw LockError.unavailable(String(cString: strerror(code)))
                }
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
            return ModelDownloadCacheAdmissionLock(
                path: path,
                descriptor: descriptor
            )
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    /// Immediate acquisition used by deterministic lock-contract tests.
    static func tryAcquire(
        at cacheRoot: URL
    ) throws -> ModelDownloadCacheAdmissionLock? {
        let (path, descriptor) = try openLockFile(at: cacheRoot)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            _ = close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                return nil
            }
            throw LockError.unavailable(String(cString: strerror(code)))
        }
        return ModelDownloadCacheAdmissionLock(
            path: path,
            descriptor: descriptor
        )
    }

    func release() {
        releaseLock.lock()
        defer { releaseLock.unlock() }
        guard !released else { return }
        released = true
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    private static func posixMessage() -> String {
        String(cString: strerror(errno))
    }

    private static func openLockFile(
        at cacheRoot: URL
    ) throws -> (path: URL, descriptor: Int32) {
        do {
            try FileManager.default.createDirectory(
                at: cacheRoot,
                withIntermediateDirectories: true
            )
        } catch {
            throw LockError.unavailable(error.localizedDescription)
        }

        let path = cacheRoot.appendingPathComponent(fileName, isDirectory: false)
        let descriptor = open(
            path.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw LockError.unavailable(posixMessage())
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            let reason = posixMessage()
            _ = close(descriptor)
            throw LockError.unavailable(reason)
        }
        return (path, descriptor)
    }
}
