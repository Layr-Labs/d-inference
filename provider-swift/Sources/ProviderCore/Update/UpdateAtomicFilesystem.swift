import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum UpdateAtomicFilesystem {
    enum DurabilitySyncResult: Equatable {
        case success
        case failure(Int32)
    }

    enum ItemKind: Equatable, Sendable {
        case directory
        case regularFile
        case symbolicLink
        case other
    }

    /// Kernel identity captured with `lstat(2)`. Recovery uses this to bind a
    /// validated path to the exact node later renamed or removed. The update
    /// lock excludes cooperating installers; the identity check also rejects a
    /// path replaced by an uncooperative local process between validation and
    /// mutation.
    struct ItemIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let kind: ItemKind
    }

    static func writeJSON<T: Encodable>(_ value: T, to destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try write(data, to: destination)
    }

    static func write(_ data: Data, to destination: URL) throws {
        let fm = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try createDirectoryDurably(directory)
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")

        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw filesystemError("open \(temporary.path)")
        }
        var shouldRemove = true
        defer {
            _ = close(descriptor)
            if shouldRemove { try? fm.removeItem(at: temporary) }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = DarwinOrGlibcWrite(descriptor, pointer, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw filesystemError("write \(temporary.path)")
                }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
        try syncRegularFile(descriptor, path: temporary.path)
        guard rename(temporary.path, destination.path) == 0 else {
            throw filesystemError("rename \(temporary.path) -> \(destination.path)")
        }
        shouldRemove = false
        try syncDirectory(directory)
    }

    /// Atomically exchange two same-volume paths. Both names always reference
    /// a complete tree; there is no interval where the live app path is absent.
    static func exchange(_ first: URL, _ second: URL) throws {
        #if canImport(Darwin)
        let result = renameatx_np(
            AT_FDCWD,
            first.path,
            AT_FDCWD,
            second.path,
            UInt32(RENAME_SWAP)
        )
        guard result == 0 else {
            throw filesystemError("exchange \(first.path) <-> \(second.path)")
        }
        try syncDirectory(first.deletingLastPathComponent())
        if first.deletingLastPathComponent() != second.deletingLastPathComponent() {
            try syncDirectory(second.deletingLastPathComponent())
        }
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    static func replace(_ source: URL, at destination: URL) throws {
        if itemExists(destination) {
            try exchange(source, destination)
        } else {
            guard rename(source.path, destination.path) == 0 else {
                throw filesystemError("rename \(source.path) -> \(destination.path)")
            }
            try syncDirectory(destination.deletingLastPathComponent())
        }
    }

    static func replace(
        _ source: URL,
        at destination: URL,
        expectedSource: ItemIdentity,
        expectedDestination: ItemIdentity?
    ) throws {
        try requireIdentity(
            expectedSource,
            at: source,
            operation: "replace source changed before rename"
        )
        try requireIdentity(
            expectedDestination,
            at: destination,
            operation: "replace destination changed before rename"
        )
        try replace(source, at: destination)
    }

    static func replaceSymlink(
        at destination: URL,
        target: String,
        expectedDirectory: ItemIdentity? = nil
    ) throws {
        let directory = destination.deletingLastPathComponent()
        let descriptor = open(
            directory.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw filesystemError(
                "open symlink destination directory \(directory.path)")
        }
        defer { _ = close(descriptor) }
        if let expectedDirectory {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw filesystemError(
                    "inspect symlink destination directory \(directory.path)")
            }
            guard itemIdentity(from: status) == expectedDirectory else {
                throw filesystemError(
                    "symlink destination directory changed before repair",
                    code: ESTALE
                )
            }
        }

        let temporary = ".\(destination.lastPathComponent).link-\(UUID().uuidString)"
        var shouldUnlink = false
        guard symlinkat(target, descriptor, temporary) == 0 else {
            throw filesystemError("create temporary symlink in \(directory.path)")
        }
        shouldUnlink = true
        defer {
            if shouldUnlink {
                _ = unlinkat(descriptor, temporary, 0)
            }
        }
        guard renameat(
            descriptor,
            temporary,
            descriptor,
            destination.lastPathComponent
        ) == 0 else {
            throw filesystemError("replace symlink \(destination.path)")
        }
        shouldUnlink = false
        try syncDirectoryDescriptor(
            descriptor,
            operation: "fsync symlink destination directory \(directory.path)"
        )
    }

    static func removeDurably(_ url: URL) throws {
        guard itemExists(url) else { return }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.removeItem(at: url)
        try syncDirectory(parent)
    }

    static func removeDurably(
        _ url: URL,
        expectedIdentity: ItemIdentity
    ) throws {
        try requireIdentity(
            expectedIdentity,
            at: url,
            operation: "remove target changed before deletion"
        )
        try removeDurably(url)
    }

    /// Remove a file/tree so the ORIGINAL path vanishes atomically. The path is
    /// first renamed to a sibling `asidePrefix<uuid>` (a single atomic rename,
    /// then the parent is fsync'd), and only afterwards is the renamed copy
    /// deleted. A crash mid-delete can never leave the original path partially
    /// populated — it is already gone — it only leaves an orphaned sibling for
    /// the caller to sweep. Used to retire a stale `Darkbloom.app` during a flat
    /// install/rollback without a window where a half-deleted app could be
    /// mistaken for a valid install.
    static func atomicRemove(_ url: URL, asidePrefix: String) throws {
        guard itemExists(url) else { return }
        let parent = url.deletingLastPathComponent()
        let aside = parent.appendingPathComponent("\(asidePrefix)\(UUID().uuidString)")
        guard rename(url.path, aside.path) == 0 else {
            throw filesystemError("rename \(url.path) aside for removal")
        }
        try syncDirectory(parent)
        try? FileManager.default.removeItem(at: aside)
    }

    static func atomicRemove(
        _ url: URL,
        asidePrefix: String,
        expectedIdentity: ItemIdentity
    ) throws {
        try requireIdentity(
            expectedIdentity,
            at: url,
            operation: "atomic removal target changed before rename"
        )
        try atomicRemove(url, asidePrefix: asidePrefix)
    }

    static func createDirectoryDurably(_ directory: URL) throws {
        let fm = FileManager.default
        if let identity = try itemIdentity(at: directory) {
            guard identity.kind == .directory else {
                throw filesystemError(
                    "refuse non-directory path \(directory.path)",
                    code: EINVAL
                )
            }
            return
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard try itemIdentity(at: directory)?.kind == .directory else {
            throw filesystemError(
                "created directory path changed \(directory.path)",
                code: ESTALE
            )
        }
        try syncDirectory(directory)
        let parent = directory.deletingLastPathComponent()
        if parent.path != directory.path {
            try syncDirectory(parent)
        }
    }

    static func sha256(file: URL) throws -> String {
        let descriptor = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw filesystemError("open \(file.path) for hashing")
        }
        defer { _ = close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw filesystemError("inspect \(file.path) for hashing")
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw filesystemError(
                "refuse non-regular hash input \(file.path)",
                code: EINVAL
            )
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: false
        )
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Content-address the complete backup tree. File paths, node kinds,
    /// symlink targets, and regular-file bytes are included in sorted order.
    static func treeHash(root: URL) throws -> String {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var entries: [URL] = []
        while let entry = enumerator.nextObject() as? URL {
            entries.append(entry)
        }
        entries.sort { relativePath($0, under: root) < relativePath($1, under: root) }

        var hasher = SHA256()
        for entry in entries {
            let relative = relativePath(entry, under: root)
            let values = try entry.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                let target = try fm.destinationOfSymbolicLink(atPath: entry.path)
                hashLine("L \(relative) \(target)", into: &hasher)
            } else if values.isDirectory == true {
                hashLine("D \(relative)", into: &hasher)
            } else if values.isRegularFile == true {
                hashLine("F \(relative)", into: &hasher)
                let handle = try FileHandle(forReadingFrom: entry)
                do {
                    while true {
                        let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
                        if chunk.isEmpty { break }
                        hasher.update(data: chunk)
                    }
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
                hashLine("", into: &hasher)
            } else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fsyncTree(_ root: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        var directories = [root]
        while let entry = enumerator.nextObject() as? URL {
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values.isRegularFile == true {
                let descriptor = open(entry.path, O_RDONLY | O_CLOEXEC)
                guard descriptor >= 0 else { throw filesystemError("open \(entry.path)") }
                defer { _ = close(descriptor) }
                try syncRegularFile(descriptor, path: entry.path)
            } else if values.isDirectory == true {
                directories.append(entry)
            }
        }
        for directory in directories.reversed() {
            try syncDirectory(directory)
        }
    }

    static func itemExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    static func itemIdentity(at url: URL) throws -> ItemIdentity? {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR {
                return nil
            }
            throw filesystemError("inspect \(url.path)", code: code)
        }
        return itemIdentity(from: status)
    }

    static func requireIdentity(
        _ expected: ItemIdentity?,
        at url: URL,
        operation: String
    ) throws {
        guard try itemIdentity(at: url) == expected else {
            throw filesystemError(operation, code: ESTALE)
        }
    }

    private static func itemIdentity(from status: stat) -> ItemIdentity {
        let kind: ItemKind
        switch status.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR):
            kind = .directory
        case mode_t(S_IFREG):
            kind = .regularFile
        case mode_t(S_IFLNK):
            kind = .symbolicLink
        default:
            kind = .other
        }
        return ItemIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            kind: kind
        )
    }

    static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func relativePath(_ url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func hashLine(_ line: String, into hasher: inout SHA256) {
        hasher.update(data: Data((line + "\n").utf8))
    }

    static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw filesystemError("open directory \(directory.path)")
        }
        let result = retrying { captureSystemCall { fsync(descriptor) } }
        _ = close(descriptor)
        if case .failure(let code) = result {
            throw filesystemError(
                "fsync directory \(directory.path)",
                code: code
            )
        }
    }

    private static func syncDirectoryDescriptor(
        _ descriptor: Int32,
        operation: String
    ) throws {
        if case .failure(let code) =
            retrying({ captureSystemCall { fsync(descriptor) } })
        {
            throw filesystemError(operation, code: code)
        }
    }

    static func synchronizeRegularFile(
        fullSync: (() -> DurabilitySyncResult)?,
        fallbackSync: () -> DurabilitySyncResult,
        operation: String
    ) throws {
        if let fullSync {
            switch retrying(fullSync) {
            case .success:
                return
            case .failure(let code):
                // Darwin's F_FULLFSYNC is the durability contract. Falling
                // back after it fails would turn a power-loss-safe commit into
                // an ordinary cache flush while reporting success.
                throw filesystemError(operation, code: code)
            }
        }

        if case .failure(let code) = retrying(fallbackSync) {
            throw filesystemError(operation, code: code)
        }
    }

    private static func syncRegularFile(
        _ descriptor: Int32,
        path: String
    ) throws {
        #if canImport(Darwin)
        let fullSync: (() -> DurabilitySyncResult)? = {
            captureFcntlCall {
                fcntl(descriptor, F_FULLFSYNC)
            }
        }
        #else
        let fullSync: (() -> DurabilitySyncResult)? = nil
        #endif
        try synchronizeRegularFile(
            fullSync: fullSync,
            fallbackSync: {
                captureSystemCall {
                    fsync(descriptor)
                }
            },
            operation: "fsync regular file \(path)"
        )
    }

    private static func retrying(
        _ operation: () -> DurabilitySyncResult
    ) -> DurabilitySyncResult {
        while true {
            let result = operation()
            if result == .failure(EINTR) {
                continue
            }
            return result
        }
    }

    private static func captureSystemCall(
        _ operation: () -> Int32
    ) -> DurabilitySyncResult {
        operation() == 0 ? .success : .failure(errno)
    }

    #if canImport(Darwin)
    private static func captureFcntlCall(
        _ operation: () -> Int32
    ) -> DurabilitySyncResult {
        operation() == -1 ? .failure(errno) : .success
    }
    #endif

    private static func filesystemError(_ operation: String) -> Error {
        filesystemError(operation, code: errno)
    }

    private static func filesystemError(
        _ operation: String,
        code: Int32
    ) -> Error {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(code)))"]
        )
    }
}

@inline(__always)
private func DarwinOrGlibcWrite(
    _ descriptor: Int32,
    _ pointer: UnsafeRawPointer,
    _ count: Int
) -> Int {
    #if canImport(Darwin)
    Darwin.write(descriptor, pointer, count)
    #else
    Glibc.write(descriptor, pointer, count)
    #endif
}
