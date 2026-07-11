import Foundation
import Darwin

protocol FanRecoveryJournaling: AnyObject {
    func recoveryRequired() throws -> Bool
    func markRecoveryRequired() throws
    func clear() throws
}

final class FanRecoveryJournal: FanRecoveryJournaling {
    static let defaultPath = URL(
        fileURLWithPath: "/Library/Application Support/Darkbloom/fan-recovery"
    )

    private let path: URL

    init(path: URL = defaultPath) {
        self.path = path
    }

    func recoveryRequired() throws -> Bool {
        var metadata = stat()
        if lstat(path.path, &metadata) != 0 {
            if errno == ENOENT {
                return false
            }
            throw posixError("inspect")
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == 0,
              metadata.st_nlink == 1 else {
            throw FanControlError.journalFailed(
                "unsafe marker at \(path.path)"
            )
        }
        return true
    }

    func markRecoveryRequired() throws {
        let directory = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let descriptor = open(
            path.path,
            O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw posixError("open")
        }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == 0,
              metadata.st_nlink == 1 else {
            throw FanControlError.journalFailed("unsafe marker metadata")
        }

        let marker = Data("fan-control-active\n".utf8)
        try marker.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = write(descriptor, pointer, remaining)
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw posixError("write")
                }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw posixError("fsync")
        }
    }

    func clear() throws {
        if unlink(path.path) != 0, errno != ENOENT {
            throw posixError("clear")
        }
    }

    private func posixError(_ operation: String) -> FanControlError {
        FanControlError.journalFailed(
            "\(operation): \(String(cString: strerror(errno)))"
        )
    }
}
