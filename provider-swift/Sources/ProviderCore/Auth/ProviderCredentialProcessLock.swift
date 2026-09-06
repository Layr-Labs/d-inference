import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Serializes credential publication and removal across CLI, app, and daemon
/// processes. The stable sidecar inode is never replaced or removed.
final class ProviderCredentialProcessLock: @unchecked Sendable {
    private static let processMutex = NSLock()

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    static func withLock<T>(
        tokenPath: URL = AuthTokenStore.tokenPath(),
        _ body: () throws -> T
    ) throws -> T {
        processMutex.lock()
        defer { processMutex.unlock() }

        let lock = try acquire(tokenPath: tokenPath)
        return try withExtendedLifetime(lock) {
            try body()
        }
    }

    private static func acquire(tokenPath: URL) throws -> ProviderCredentialProcessLock {
        let directory = tokenPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let path = directory.appendingPathComponent(
            ".provider-credential.lock",
            isDirectory: false
        )
        let descriptor = open(
            path.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw ProviderCredentialStoreError.lockUnavailable(posixMessage())
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            let reason = posixMessage()
            _ = close(descriptor)
            throw ProviderCredentialStoreError.lockUnavailable(reason)
        }

        while flock(descriptor, LOCK_EX) != 0 {
            let code = errno
            if code == EINTR {
                continue
            }
            let reason = String(cString: strerror(code))
            _ = close(descriptor)
            throw ProviderCredentialStoreError.lockUnavailable(reason)
        }
        return ProviderCredentialProcessLock(descriptor: descriptor)
    }

    private static func posixMessage() -> String {
        String(cString: strerror(errno))
    }
}
