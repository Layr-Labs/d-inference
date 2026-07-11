import Foundation
import Darwin

final class FanControlProcessLock {
    static let defaultPath = URL(fileURLWithPath: "/var/run/darkbloom-fan.lock")

    private let descriptor: Int32
    private var released = false
    private let releaseLock = NSLock()

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    static func acquire(
        at path: URL = defaultPath
    ) throws -> FanControlProcessLock {
        let descriptor = open(
            path.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw FanControlError.lockFailed(
                String(cString: strerror(errno))
            )
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw FanControlError.anotherControllerRunning
            }
            throw FanControlError.lockFailed(
                String(cString: strerror(code))
            )
        }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            let code = errno
            flock(descriptor, LOCK_UN)
            close(descriptor)
            throw FanControlError.lockFailed(
                String(cString: strerror(code))
            )
        }
        guard metadata.st_uid == 0,
              metadata.st_nlink == 1,
              (metadata.st_mode & S_IFMT) == S_IFREG else {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            throw FanControlError.lockFailed("unsafe lock-file metadata")
        }

        return FanControlProcessLock(descriptor: descriptor)
    }

    private func release() {
        releaseLock.lock()
        defer { releaseLock.unlock() }
        guard !released else { return }
        released = true
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
