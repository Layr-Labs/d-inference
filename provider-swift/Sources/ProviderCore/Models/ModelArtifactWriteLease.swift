import Darwin
import Foundation

/// Serializes foreground/background writers across processes. flock is released
/// by the OS after a crash; waiting is cancellable and never blocks an actor.
final class ModelArtifactWriteLease: @unchecked Sendable {
    private let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(modelID: String) async throws -> ModelArtifactWriteLease {
        let directory = ModelDownloader.cacheModelDirectory(for: modelID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent(".artifact-writer.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
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
