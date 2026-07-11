import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One kernel-owned lock for every process that can mutate the provider install.
///
/// `flock(2)` ownership is attached to the open file description, so the kernel
/// releases the lock if an updater is killed or crashes. The descriptor is also
/// close-on-exec: a successful provider restart cannot accidentally inherit the
/// updater lock and deadlock the next watchdog tick.
public final class UpdateProcessLock: @unchecked Sendable {
    public struct Owner: Codable, Sendable, Equatable {
        public let pid: Int32
        public let operation: String
        public let acquiredAt: Double

        enum CodingKeys: String, CodingKey {
            case pid
            case operation
            case acquiredAt = "acquired_at"
        }
    }

    public enum LockError: Error, CustomStringConvertible, Sendable {
        case busy(owner: Owner?)
        case openFailed(String)
        case lockFailed(String)

        public var description: String {
            switch self {
            case .busy(let owner):
                if let owner {
                    return "another update operation owns the lock (pid \(owner.pid), \(owner.operation))"
                }
                return "another update operation owns the lock"
            case .openFailed(let reason):
                return "could not open update lock: \(reason)"
            case .lockFailed(let reason):
                return "could not acquire update lock: \(reason)"
            }
        }
    }

    private let descriptor: Int32
    public let path: URL
    public let owner: Owner
    private let releaseMutex = NSLock()
    private var released = false

    private init(descriptor: Int32, path: URL, owner: Owner) {
        self.descriptor = descriptor
        self.path = path
        self.owner = owner
    }

    deinit {
        release()
    }

    public static func acquire(
        at path: URL,
        operation: String,
        timeout: TimeInterval = 0
    ) throws -> UpdateProcessLock {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw LockError.openFailed(error.localizedDescription)
        }

        let descriptor = open(path.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw LockError.openFailed(posixMessage())
        }

        let deadline = Date().addingTimeInterval(max(0, timeout))
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR {
                continue
            }
            if code == EWOULDBLOCK || code == EAGAIN {
                if timeout > 0, Date() < deadline {
                    Thread.sleep(forTimeInterval: min(0.05, deadline.timeIntervalSinceNow))
                    continue
                }
                let owner = readOwner(from: descriptor)
                close(descriptor)
                throw LockError.busy(owner: owner)
            }
            let reason = String(cString: strerror(code))
            close(descriptor)
            throw LockError.lockFailed(reason)
        }

        let owner = Owner(
            pid: getpid(),
            operation: operation,
            acquiredAt: Date().timeIntervalSince1970
        )
        do {
            try writeOwner(owner, to: descriptor)
        } catch {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            throw LockError.lockFailed(error.localizedDescription)
        }
        return UpdateProcessLock(descriptor: descriptor, path: path, owner: owner)
    }

    public func release() {
        releaseMutex.lock()
        defer { releaseMutex.unlock() }
        guard !released else { return }
        released = true
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    private static func writeOwner(_ owner: Owner, to descriptor: Int32) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(owner)
        data.append(0x0A)

        guard ftruncate(descriptor, 0) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSUnderlyingErrorKey: String(cString: strerror(errno)),
            ])
        }
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }

        try data.withUnsafeBytes { rawBuffer in
            guard var base = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = write(descriptor, base, remaining)
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [
                        NSUnderlyingErrorKey: String(cString: strerror(errno)),
                    ])
                }
                remaining -= count
                base = base.advanced(by: count)
            }
        }
        guard fsync(descriptor) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func readOwner(from descriptor: Int32) -> Owner? {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = read(descriptor, &bytes, bytes.count)
        guard count > 0 else { return nil }
        return try? JSONDecoder().decode(Owner.self, from: Data(bytes.prefix(count)))
    }

    private static func posixMessage() -> String {
        String(cString: strerror(errno))
    }
}
