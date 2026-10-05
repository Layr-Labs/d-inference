import Darwin
import Foundation

/// Serializes foreground/background writers and removal across processes.
/// Lock files live outside the removable model tree and are never removed:
/// unlinking a held flock would let another writer lock a different inode.
/// The OS releases the lease after a crash; asynchronous waiting is cancellable.
final class ModelArtifactWriteLease: @unchecked Sendable {
    private let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }

    private static func openDescriptor(modelID: String) throws -> Int32 {
        let modelDirectory = ModelDownloader.cacheModelDirectory(for: modelID)
        let directory = modelDirectory.deletingLastPathComponent()
            .appendingPathComponent(".artifact-writer-locks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(modelDirectory.lastPathComponent).path
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return fd
    }

    /// User-facing removal and verification must not wait behind a potentially
    /// long download or a staged revision holding its lease during rollout jitter.
    static func acquireIfAvailable(modelID: String, operation: String = "removal") throws -> ModelArtifactWriteLease {
        let fd = try openDescriptor(modelID: modelID)
        do {
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                if errno == EINTR { continue }
                if errno == EWOULDBLOCK {
                    throw ModelCatalogError.downloadFailed(
                        "\(modelID) is being downloaded, updated or verified by another process; retry \(operation) after it finishes")
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return ModelArtifactWriteLease(fd)
        } catch { close(fd); throw error }
    }

    static func acquire(modelID: String) async throws -> ModelArtifactWriteLease {
        let fd = try openDescriptor(modelID: modelID)
        do {
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EINTR else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                try await taskSleep(.milliseconds(250))
            }
            try Task.checkCancellation()
            return ModelArtifactWriteLease(fd)
        } catch { close(fd); throw error }
    }

    func release() { flock(descriptor, LOCK_UN) }
    deinit { close(descriptor) }
}
