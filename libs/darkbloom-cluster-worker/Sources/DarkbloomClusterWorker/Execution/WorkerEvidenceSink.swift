import Darwin
import Foundation

/// Qualification sidecars for a worker started with `--evidence-directory`.
/// Not part of the serving wire protocol. One file per request; a failed or
/// partial file stays as evidence of that attempt and is never replaced.
final class WorkerEvidenceSink {
    enum Failure: Error { case invalidDirectory, invalidRecord, create, write, sync, expired }
    private let directory: Int32
    private var requests = Set<UUID>()
    static let maximumBytes = 16 * 1024 * 1024
    static let maximumRequests = 16

    /// The directory must already exist, belong to this user and be private.
    init(path: String) throws {
        guard path.hasPrefix("/"), path.utf8.count <= 1024, !path.contains("\0") else {
            throw Failure.invalidDirectory
        }
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.invalidDirectory }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
            Darwin.close(descriptor); throw Failure.invalidDirectory
        }
        directory = descriptor
    }

    static func fileName(_ requestID: UUID) -> String { requestID.uuidString.lowercased() + ".json" }

    func publish(_ evidence: Data, requestID: UUID, deadline: UInt64) throws {
        guard !evidence.isEmpty, evidence.count <= Self.maximumBytes,
              requests.count < Self.maximumRequests, !requests.contains(requestID) else { throw Failure.invalidRecord }
        func check() throws {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw Failure.expired }
        }
        try check()
        let descriptor = openat(directory, Self.fileName(requestID),
                                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.create }
        defer { Darwin.close(descriptor) }
        requests.insert(requestID)
        var offset = 0
        while offset < evidence.count {
            try check()
            let count = evidence.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), min(65_536, evidence.count - offset))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure.write }
            offset += count
        }
        try check()
        guard fsync(descriptor) == 0, fsync(directory) == 0 else { throw Failure.sync }
        try check()
    }

    deinit { Darwin.close(directory) }
}
