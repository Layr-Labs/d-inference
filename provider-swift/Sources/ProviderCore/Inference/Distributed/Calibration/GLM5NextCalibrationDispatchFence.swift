import Darwin
import Foundation

/// Per-pair quarantine survives command death. Neither a report nor local-only
/// exit deletes it. Recovery of an unresolved fence is a separate parent action.
final class GLM5NextCalibrationDispatchFence {
    typealias W = GLM5NextCalibrationDispatchWire
    private let directory: URL
    private let pending: URL
    private var descriptor: Int32 = -1
    private var directoryIdentity: (dev_t, ino_t)?
    private var pendingIdentity: DistributedInstalledFiles.Identity?
    init(directory: URL, pair: GLM5NextCalibrationInstalledPair, sessionID: UUID,
         epoch: UUID, requestID: UUID) throws {
        try pair.requireUnchanged()
        try ClusterConfigurationFiles.ensureDirectory(directory, create: true, privateMode: true)
        self.directory = directory
        let name = W.hash(Data((pair.clusterID + ":" + pair.record.link.edgeID).utf8))
        pending = directory.appendingPathComponent(name + ".finite-pending.json")
        let lock = directory.appendingPathComponent(name + ".finite-lock")
        let fd = Darwin.open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw W.invalid("finite pair lock unavailable") }
        descriptor = fd
        do {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
                  flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw W.invalid("finite pair already owned") }
            var folder = stat()
            guard lstat(directory.path, &folder) == 0, folder.st_mode & S_IFMT == S_IFDIR else { throw W.invalid("finite fence directory changed") }
            directoryIdentity = (folder.st_dev, folder.st_ino)
            guard !FileManager.default.fileExists(atPath: pending.path) else { throw W.invalid("finite pair retirement unresolved") }
            let archive = directory.appendingPathComponent(sessionID.uuidString.lowercased() + ".finite-result.json")
            guard !FileManager.default.fileExists(atPath: archive.path) else { throw W.invalid("finite session already retired") }
            struct Pending: Codable { let version: Int; let sessionID: UUID; let epoch: UUID; let requestID: UUID }
            let record = try W.canonical(Pending(version: 1, sessionID: sessionID, epoch: epoch, requestID: requestID))
            try write(record, at: pending)
            pendingIdentity = try DistributedInstalledFiles.verify(pending, expectedSHA256: W.hash(record),
                maximumBytes: 16 << 10, deadline: DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
            try requireOriginal()
        } catch { Darwin.close(fd); descriptor = -1; throw error }
    }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
    /// Opaque receipt can be constructed only by the concrete dispatch driver
    /// after both authenticated results and their exact digest acknowledgments.
    func finish(_ receipt: GLM5NextCalibrationDispatchTerminalReceipt,
                afterArchiveSynced: (() throws -> Void)? = nil) throws -> URL {
        try requireOriginal()
        let archive = directory.appendingPathComponent(receipt.sessionID.uuidString.lowercased() + ".finite-result.json")
        try write(receipt.archive, at: archive)
        // Explicit pause/observation seam; real writes/fsync above and identity
        // recheck/unlink/fsync below remain mandatory. Production passes nil.
        try afterArchiveSynced?()
        try requireOriginal()
        guard unlink(pending.path) == 0 else { throw W.invalid("finite pair quarantine unresolved") }
        try syncDirectory()
        return archive
    }
    private func requireOriginal() throws {
        var folder = stat()
        guard descriptor >= 0, let identity = directoryIdentity,
              lstat(directory.path, &folder) == 0, folder.st_mode & S_IFMT == S_IFDIR,
              folder.st_uid == geteuid(), folder.st_mode & 0o077 == 0,
              folder.st_dev == identity.0, folder.st_ino == identity.1,
              let pendingIdentity else { throw W.invalid("finite fence directory changed") }
        try pendingIdentity.requireUnchanged()
    }
    private func write(_ data: Data, at url: URL) throws {
        guard data.count <= W.maximumBytes else { throw W.invalid("finite receipt too large") }
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw W.invalid("finite receipt exists/unavailable") }
        defer { Darwin.close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw W.invalid("finite receipt write") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw W.invalid("finite receipt sync") }
        try syncDirectory()
    }
    private func syncDirectory() throws {
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw W.invalid("finite directory sync") }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw W.invalid("finite directory sync") }
    }
}
