import CryptoKit
import Darwin
import Foundation
import SandboxGuestProtocol

/// Every lookup starts at an open workspace descriptor. Uploads remain unlinked
/// until complete, then APFS clones the descriptor to an unused destination.
/// A tenant never controls a staging path or a privileged file descriptor.
public final class GuestWorkspace: @unchecked Sendable {
    private final class Upload {
        let file: Int32
        let parent: Int32
        let name: String
        let path: String
        let size: UInt64
        let digest: String
        var offset: UInt64 = 0
        var hasher = SHA256()
        init(file: Int32, parent: Int32, name: String, path: String, size: UInt64, digest: String) {
            self.file = file; self.parent = parent; self.name = name
            self.size = size; self.digest = digest
            self.path = path
        }
        deinit { close(file); close(parent) }
    }
    private let downloadEpoch = UUID()
    private let root: Int32
    private let device: dev_t
    private let tenantUID: uid_t
    private let tenantGID: gid_t
    private let lock = NSLock()
    private var uploads: [UUID: Upload] = [:]
    private var completed: [UUID: GuestUploadStatus] = [:]
    private var retired: Set<UUID> = []
    private var aborted: [UUID: GuestUploadStatus] = [:]

    public init(path: String, tenantUID: uid_t, tenantGID: gid_t,
                requireSeparateVolume: Bool = true) throws {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw GuestProtocolError.invalidConfiguration }
        var info = stat(), boot = stat()
        guard fstat(descriptor, &info) == 0, stat("/", &boot) == 0,
              !requireSeparateVolume || (info.st_dev != boot.st_dev && info.st_uid == 0
                  && info.st_gid == tenantGID && info.st_mode & 0o1777 == 0o1770)
        else { close(descriptor); throw GuestProtocolError.invalidConfiguration }
        self.root = descriptor; self.device = info.st_dev
        self.tenantUID = tenantUID; self.tenantGID = tenantGID
    }
    deinit { close(root) }

    public func directoryDescriptor(_ path: String) throws -> Int32 {
        try descend(GuestPath.components(path, allowRoot: true))
    }

    public func makeDirectory(_ path: String) throws {
        try lock.withLock {
            let parts = try GuestPath.components(path)
            let parent = try descend(Array(parts.dropLast()))
            defer { close(parent) }
            let created = mkdirat(parent, parts.last!, 0o700) == 0
            guard created || errno == EEXIST else { throw GuestProtocolError.invalidPath }
            let fd = openat(parent, parts.last!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw GuestProtocolError.invalidPath }
            defer { close(fd) }
            if !created {
                var metadata = stat()
                guard fstat(fd, &metadata) == 0, metadata.st_dev == device,
                      metadata.st_uid == tenantUID, metadata.st_mode & S_IFMT == S_IFDIR
                else { throw GuestProtocolError.invalidPath }
                return
            }
            guard fchown(fd, tenantUID, tenantGID) == 0, fsync(parent) == 0 else {
                throw GuestProtocolError.invalidPath
            }
        }
    }

    public func begin(id: UUID, path: String, size: UInt64, sha256: String) throws {
        try lock.withLock {
            if let state = statusWithoutLock(id: id) {
                guard state.path == path, state.size == size, state.sha256 == sha256 else {
                    throw GuestProtocolError.transferConflict
                }
                return
            }
            guard !retired.contains(id), uploads.count < 8,
                  completed.count + uploads.count + retired.count + aborted.count < 4096,
                  size <= 50 * 1_073_741_824,
                  sha256.utf8.count == 64,
                  sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { throw GuestProtocolError.transferConflict }
            let parts = try GuestPath.components(path)
            let parent = try descend(Array(parts.dropLast()))
            var retained = false
            defer { if !retained { close(parent) } }
            let temporary = ".darkbloom-upload-\(UUID().uuidString)"
            let file = openat(root, temporary, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard file >= 0 else { throw GuestProtocolError.unavailable }
            guard unlinkat(root, temporary, 0) == 0 else {
                close(file); throw GuestProtocolError.unavailable
            }
            uploads[id] = Upload(file: file, parent: parent, name: parts.last!, path: path, size: size, digest: sha256)
            retained = true
        }
    }

    public func append(id: UUID, offset: UInt64, data: Data) throws {
        try lock.withLock {
            guard let upload = uploads[id], offset <= upload.offset,
                  !data.isEmpty, data.count <= GuestProtocolLimits.maximumChunkBytes,
                  offset <= upload.size, UInt64(data.count) <= upload.size - offset
            else { throw GuestProtocolError.transferConflict }
            if offset < upload.offset {
                guard UInt64(data.count) <= upload.offset - offset else { throw GuestProtocolError.transferConflict }
                var existing = Data(count: data.count)
                let count = existing.withUnsafeMutableBytes {
                    pread(upload.file, $0.baseAddress, $0.count, off_t(offset))
                }
                guard count == data.count, existing == data else { throw GuestProtocolError.transferConflict }
                return
            }
            do { try GuestDescriptor.write(upload.file, data: data) }
            catch { uploads.removeValue(forKey: id); retired.insert(id); throw error }
            upload.hasher.update(data: data); upload.offset += UInt64(data.count)
        }
    }

    public func commit(id: UUID) throws {
        try lock.withLock {
            if completed[id] != nil { return }
            guard let upload = uploads[id] else { throw GuestProtocolError.transferConflict }
            guard upload.offset == upload.size else { throw GuestProtocolError.transferConflict }
            defer {
                uploads.removeValue(forKey: id)
                if completed[id] == nil { retired.insert(id) }
            }
            guard upload.hasher.finalize().map({ String(format: "%02x", $0) }).joined() == upload.digest,
                  fchown(upload.file, tenantUID, tenantGID) == 0,
                  fchmod(upload.file, 0o600) == 0,
                  fsync(upload.file) == 0,
                  fclonefileat(upload.file, upload.parent, upload.name, 0) == 0
            else { throw GuestProtocolError.transferConflict }
            guard fsync(upload.parent) == 0 else { throw GuestProtocolError.publicationUncertain }
            completed[id] = GuestUploadStatus(path: upload.path, size: upload.size,
                sha256: upload.digest, offset: upload.size, committed: true)
        }
    }

    public func abort(id: UUID) throws {
        try lock.withLock {
            if completed[id] != nil || aborted[id] != nil { return }
            guard let upload = uploads.removeValue(forKey: id) else { throw GuestProtocolError.transferConflict }
            aborted[id] = GuestUploadStatus(path: upload.path, size: upload.size,
                sha256: upload.digest, offset: upload.offset, state: .aborted)
        }
    }

    public func status(id: UUID) throws -> GuestUploadStatus {
        try lock.withLock {
            guard let state = statusWithoutLock(id: id) else { throw GuestProtocolError.transferConflict }
            return state
        }
    }

    private func statusWithoutLock(id: UUID) -> GuestUploadStatus? {
        if let state = completed[id] { return state }
        if let state = aborted[id] { return state }
        guard let upload = uploads[id] else { return nil }
        return GuestUploadStatus(path: upload.path, size: upload.size, sha256: upload.digest,
            offset: upload.offset, committed: false)
    }

    public func download(path: String, offset: UInt64, maximumBytes: Int, version: String? = nil) throws -> GuestResponse {
        try lock.withLock {
            guard (1...GuestProtocolLimits.maximumChunkBytes).contains(maximumBytes), offset <= UInt64(Int64.max)
            else { throw GuestProtocolError.invalidMessage }
            let parts = try GuestPath.components(path)
            let parent = try descend(Array(parts.dropLast()))
            defer { close(parent) }
            let fd = openat(parent, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw GuestProtocolError.invalidPath }
            defer { close(fd) }
            var before = stat(), after = stat()
            guard fstat(fd, &before) == 0, before.st_dev == device,
                  before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
                  before.st_uid == tenantUID, before.st_size >= 0,
                  offset <= UInt64(before.st_size), lseek(fd, Int64(offset), SEEK_SET) >= 0
            else { throw GuestProtocolError.invalidPath }
            let currentVersion = downloadVersion(before)
            guard (offset == 0 || version != nil), version == nil || version == currentVersion else {
                throw GuestProtocolError.fileChanged
            }
            let size = min(maximumBytes, Int(UInt64(before.st_size) - offset))
            let data = try GuestDescriptor.read(fd, count: size)
            guard fstat(fd, &after) == 0, after.st_size == before.st_size,
                  after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
                  after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
                  after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
                  after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
            else { throw GuestProtocolError.fileChanged }
            var result = GuestResponse(id: UUID(), success: true)
            result.data = data; result.offset = offset; result.size = UInt64(before.st_size)
            result.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            result.version = currentVersion
            return result
        }
    }

    private func downloadVersion(_ info: stat) -> String {
        let identity = "\(downloadEpoch.uuidString):\(info.st_dev):\(info.st_ino):\(info.st_size):"
            + "\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):"
            + "\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func descend(_ components: [String]) throws -> Int32 {
        var current = fcntl(root, F_DUPFD_CLOEXEC, 0)
        guard current >= 0 else { throw GuestProtocolError.unavailable }
        do {
            for part in components {
                let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw GuestProtocolError.invalidPath }
                var info = stat()
                guard fstat(next, &info) == 0, info.st_dev == device else {
                    close(next); throw GuestProtocolError.invalidPath
                }
                close(current); current = next
            }
            return current
        } catch { close(current); throw error }
    }
}
