import CryptoKit
import Darwin
import Foundation

/// A complete, inode-bound description of one relocation endpoint.
///
/// The inode identity detects path replacement while the content hash detects
/// in-place mutation of any file, directory, permission, or symlink target in
/// the tree.
struct AppRelocationArtifactState: Codable, Equatable {
    let identity: String
    let contentHash: String

    enum CodingKeys: String, CodingKey {
        case identity
        case contentHash = "content_hash"
    }
}

/// Low-level durability and identity primitives for app relocation.
///
/// Keeping these operations separate from the journal state machine makes the
/// ordering contract explicit: regular files receive `fsync` plus
/// `F_FULLFSYNC`, directory entries are synced after every rename, and a state
/// is accepted for journaling only when it is unchanged across a full-tree
/// synchronization.
enum AppRelocationFilesystem {
    enum PathKind: Equatable {
        case directory
        case regularFile
        case symbolicLink
        case unsupported(mode: mode_t)
    }

    private struct TreeEntry {
        let url: URL
        let relativePath: String
    }

    static func itemExists(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }

    static func pathKind(at url: URL) throws -> PathKind? {
        var status = stat()
        if lstat(url.path, &status) != 0 {
            if errno == ENOENT {
                return nil
            }
            throw filesystemError("inspect \(url.path)")
        }
        switch status.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR):
            return .directory
        case mode_t(S_IFREG):
            return .regularFile
        case mode_t(S_IFLNK):
            return .symbolicLink
        default:
            return .unsupported(mode: status.st_mode & mode_t(S_IFMT))
        }
    }

    static func optionalState(
        at url: URL
    ) throws -> AppRelocationArtifactState? {
        var status = stat()
        if lstat(url.path, &status) != 0 {
            if errno == ENOENT {
                return nil
            }
            throw filesystemError("inspect \(url.path)")
        }
        return try state(at: url, initialStatus: status)
    }

    static func state(
        at url: URL
    ) throws -> AppRelocationArtifactState {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw filesystemError("inspect \(url.path)")
        }
        return try state(at: url, initialStatus: status)
    }

    static func synchronizedOptionalState(
        at url: URL
    ) throws -> AppRelocationArtifactState? {
        guard let before = try optionalState(at: url) else {
            return nil
        }
        try fullySyncTree(url)
        guard let after = try optionalState(at: url), after == before else {
            throw filesystemError(
                "refuse \(url.path), which changed while being synchronized",
                code: EBUSY
            )
        }
        return after
    }

    static func synchronizedState(
        at url: URL
    ) throws -> AppRelocationArtifactState {
        guard let state = try synchronizedOptionalState(at: url) else {
            throw filesystemError("synchronize missing path \(url.path)", code: ENOENT)
        }
        return state
    }

    static func optionalIdentity(at url: URL) throws -> String? {
        var status = stat()
        if lstat(url.path, &status) != 0 {
            if errno == ENOENT {
                return nil
            }
            throw filesystemError("inspect \(url.path)")
        }
        return identity(of: status)
    }

    static func fullySyncTree(_ root: URL) throws {
        let entries = try treeEntries(root)
        var directories: [URL] = []
        for entry in entries {
            var status = stat()
            guard lstat(entry.url.path, &status) == 0 else {
                throw filesystemError("inspect \(entry.url.path)")
            }
            switch status.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFREG):
                let descriptor = open(
                    entry.url.path,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW
                )
                guard descriptor >= 0 else {
                    throw filesystemError("open \(entry.url.path) for full sync")
                }
                do {
                    var openedStatus = stat()
                    guard fstat(descriptor, &openedStatus) == 0 else {
                        throw filesystemError(
                            "inspect \(entry.url.path) before full sync"
                        )
                    }
                    guard openedStatus.st_mode & mode_t(S_IFMT)
                            == mode_t(S_IFREG)
                    else {
                        throw filesystemError(
                            "refuse non-regular full sync at \(entry.url.path)",
                            code: EFTYPE
                        )
                    }
                    try fullSync(descriptor, path: entry.url.path)
                    guard close(descriptor) == 0 else {
                        throw filesystemError(
                            "close \(entry.url.path) after full sync"
                        )
                    }
                } catch {
                    _ = close(descriptor)
                    throw error
                }
            case mode_t(S_IFDIR):
                directories.append(entry.url)
            case mode_t(S_IFLNK):
                continue
            default:
                throw filesystemError(
                    "refuse unsupported file type at \(entry.url.path)",
                    code: EFTYPE
                )
            }
        }
        for directory in directories.sorted(by: {
            $0.pathComponents.count > $1.pathComponents.count
        }) {
            try syncDirectory(directory)
        }
        try syncDirectory(root.deletingLastPathComponent())
    }

    static func writeAtomically(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).tmp-\(UUID().uuidString.lowercased())"
        )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw filesystemError("create \(temporary.path)")
        }
        var descriptorIsOpen = true
        var shouldRemove = true
        defer {
            if descriptorIsOpen {
                _ = close(descriptor)
            }
            if shouldRemove {
                try? FileManager.default.removeItem(at: temporary)
            }
        }

        try data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw filesystemError("write \(temporary.path)")
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
        try fullSync(descriptor, path: temporary.path)
        guard close(descriptor) == 0 else {
            throw filesystemError("close \(temporary.path)")
        }
        descriptorIsOpen = false
        guard rename(temporary.path, destination.path) == 0 else {
            throw filesystemError(
                "publish \(temporary.path) as \(destination.path)"
            )
        }
        shouldRemove = false
        try syncDirectory(directory)
    }

    static func readRegularFile(
        _ url: URL,
        maximumBytes: Int
    ) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw filesystemError("open \(url.path)")
        }
        defer { _ = close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw filesystemError("inspect \(url.path)")
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw filesystemError(
                "refuse non-regular journal at \(url.path)",
                code: EFTYPE
            )
        }
        guard status.st_size >= 0,
              status.st_size <= off_t(maximumBytes)
        else {
            throw filesystemError(
                "refuse oversized journal at \(url.path)",
                code: EFBIG
            )
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else {
                throw filesystemError("read \(url.path)")
            }
            if count == 0 {
                return data
            }
            guard data.count + count <= maximumBytes else {
                throw filesystemError(
                    "refuse oversized journal at \(url.path)",
                    code: EFBIG
                )
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    static func exchange(_ first: URL, _ second: URL) throws {
        guard first.deletingLastPathComponent().standardizedFileURL
                == second.deletingLastPathComponent().standardizedFileURL
        else {
            throw filesystemError(
                "refuse cross-directory relocation exchange",
                code: EXDEV
            )
        }
        guard renameatx_np(
            AT_FDCWD,
            first.path,
            AT_FDCWD,
            second.path,
            UInt32(RENAME_SWAP)
        ) == 0 else {
            throw filesystemError("exchange \(first.path) with \(second.path)")
        }
        try syncDirectory(first.deletingLastPathComponent())
    }

    static func renameExclusive(_ source: URL, to destination: URL) throws {
        guard source.deletingLastPathComponent().standardizedFileURL
                == destination.deletingLastPathComponent().standardizedFileURL
        else {
            throw filesystemError(
                "refuse cross-directory relocation rename",
                code: EXDEV
            )
        }
        guard renameatx_np(
            AT_FDCWD,
            source.path,
            AT_FDCWD,
            destination.path,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw filesystemError(
                "rename \(source.path) to \(destination.path)"
            )
        }
        try syncDirectory(source.deletingLastPathComponent())
    }

    static func removeDurably(_ url: URL) throws {
        guard itemExists(url) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw AppRelocationTransaction.TransactionError.filesystem(
                operation: "remove \(url.path)",
                reason: error.localizedDescription
            )
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw filesystemError("open directory \(directory.path) for sync")
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let saved = errno
            _ = close(descriptor)
            throw filesystemError(
                "inspect directory \(directory.path) for sync",
                code: saved
            )
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            _ = close(descriptor)
            throw filesystemError(
                "refuse non-directory sync at \(directory.path)",
                code: ENOTDIR
            )
        }
        while fsync(descriptor) != 0 {
            if errno == EINTR {
                continue
            }
            let saved = errno
            _ = close(descriptor)
            throw filesystemError(
                "sync directory \(directory.path)",
                code: saved
            )
        }
        guard close(descriptor) == 0 else {
            throw filesystemError("close directory \(directory.path) after sync")
        }
    }

    private static func state(
        at url: URL,
        initialStatus: stat
    ) throws -> AppRelocationArtifactState {
        let initialIdentity = identity(of: initialStatus)
        let hash = try treeHash(root: url)
        var finalStatus = stat()
        guard lstat(url.path, &finalStatus) == 0 else {
            throw filesystemError("reinspect \(url.path) after hashing")
        }
        guard identity(of: finalStatus) == initialIdentity else {
            throw filesystemError(
                "refuse \(url.path), which changed while hashing",
                code: EBUSY
            )
        }
        return AppRelocationArtifactState(
            identity: initialIdentity,
            contentHash: hash
        )
    }

    private static func identity(of status: stat) -> String {
        "\(UInt64(status.st_dev)):\(UInt64(status.st_ino))"
    }

    private static func treeHash(root: URL) throws -> String {
        let entries = try treeEntries(root).sorted {
            $0.relativePath < $1.relativePath
        }
        var hasher = SHA256()
        for entry in entries {
            var status = stat()
            guard lstat(entry.url.path, &status) == 0 else {
                throw filesystemError(
                    "inspect \(entry.url.path) while hashing"
                )
            }
            let relative = entry.relativePath
            let permissions = String(status.st_mode & mode_t(0o7777))
            switch status.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFDIR):
                hashFields(["directory", relative, permissions], into: &hasher)
            case mode_t(S_IFLNK):
                let target: String
                do {
                    target = try FileManager.default.destinationOfSymbolicLink(
                        atPath: entry.url.path
                    )
                } catch {
                    throw AppRelocationTransaction.TransactionError.filesystem(
                        operation: "read symbolic link \(entry.url.path)",
                        reason: error.localizedDescription
                    )
                }
                hashFields(
                    ["symlink", relative, permissions, target],
                    into: &hasher
                )
            case mode_t(S_IFREG):
                hashFields(
                    [
                        "file",
                        relative,
                        permissions,
                        try regularFileHash(entry.url),
                    ],
                    into: &hasher
                )
            default:
                throw filesystemError(
                    "refuse unsupported file type at \(entry.url.path)",
                    code: EFTYPE
                )
            }
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func regularFileHash(_ url: URL) throws -> String {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw filesystemError("open \(url.path) for hashing")
        }
        defer { _ = close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else {
            throw filesystemError("refuse non-regular file at \(url.path)")
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else {
                throw filesystemError("read \(url.path) for hashing")
            }
            if count == 0 {
                break
            }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func treeEntries(_ root: URL) throws -> [TreeEntry] {
        var rootStatus = stat()
        guard lstat(root.path, &rootStatus) == 0 else {
            throw filesystemError("inspect tree root \(root.path)")
        }
        var entries = [TreeEntry(url: root, relativePath: ".")]
        guard rootStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            return entries
        }

        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw filesystemError("enumerate \(root.path)", code: EIO)
        }

        // Derive lexical paths from directory-entry names. Standardizing each
        // URL can resolve a dangling symlink differently after its target
        // appears, changing the hash even though the tree itself is untouched.
        var pathComponents: [String] = []
        while let entry = enumerator.nextObject() as? URL {
            let parentCount = enumerator.level - 1
            guard parentCount >= 0, parentCount <= pathComponents.count else {
                throw filesystemError(
                    "enumerate invalid tree depth under \(root.path)",
                    code: EIO
                )
            }
            pathComponents.removeLast(pathComponents.count - parentCount)
            pathComponents.append(entry.lastPathComponent)
            entries.append(
                TreeEntry(
                    url: entry,
                    relativePath: pathComponents.joined(separator: "/")
                )
            }
        }
        if let enumerationError {
            throw AppRelocationTransaction.TransactionError.filesystem(
                operation: "enumerate \(root.path)",
                reason: enumerationError.localizedDescription
            )
        }
        return entries
    }

    private static func hashFields(
        _ fields: [String],
        into hasher: inout SHA256
    ) {
        for field in fields {
            let data = Data(field.utf8)
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) {
                hasher.update(data: Data($0))
            }
            hasher.update(data: data)
        }
    }

    private static func fullSync(_ descriptor: Int32, path: String) throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR {
                continue
            }
            throw filesystemError("sync \(path)")
        }
        while fcntl(descriptor, F_FULLFSYNC) != 0 {
            if errno == EINTR {
                continue
            }
            throw filesystemError("fully sync \(path)")
        }
    }

    static func filesystemError(
        _ operation: String,
        code: Int32 = errno
    ) -> AppRelocationTransaction.TransactionError {
        .filesystem(
            operation: operation,
            reason: String(cString: strerror(code))
        )
    }
}
