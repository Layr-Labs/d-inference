import Darwin
import Foundation

enum SandboxDescriptorIOError: Error, Equatable {
    case sourceNotRegularFile
    case sourceChanged
    case destinationExists
    case unsafeDestination
    case io(Int32)
}

enum SandboxDescriptorIO {
    static func withStableSource<Result>(
        at source: URL,
        _ operation: (Int32, stat) throws -> Result
    ) throws -> Result {
        let openedSource = try StableSource(source)
        defer { openedSource.close() }

        let result: Result
        do {
            result = try operation(
                openedSource.descriptor,
                openedSource.metadata
            )
        } catch {
            try openedSource.requireUnchanged()
            throw error
        }
        try openedSource.requireUnchanged()
        return result
    }

    static func withExclusiveDestination<Result>(
        at destination: URL,
        _ operation: (Int32) throws -> Result
    ) throws -> Result {
        let pending = try PendingDestination(destination)
        defer { pending.cleanup() }

        let result = try operation(pending.descriptor)
        try pending.synchronize()
        try pending.publish()
        return result
    }

    static func withStableSourceAndExclusiveDestination<Result>(
        source: URL,
        destination: URL,
        _ operation: (Int32, stat, Int32) throws -> Result
    ) throws -> Result {
        let openedSource = try StableSource(source)
        defer { openedSource.close() }
        let pending = try PendingDestination(destination)
        defer { pending.cleanup() }

        let result: Result
        do {
            result = try operation(
                openedSource.descriptor,
                openedSource.metadata,
                pending.descriptor
            )
            try pending.synchronize()
        } catch {
            try openedSource.requireUnchanged()
            throw error
        }
        try openedSource.requireUnchanged()
        try pending.publish()
        return result
    }

    static func readExactly(
        _ count: Int,
        from descriptor: Int32,
        truncated: @autoclosure () -> Error
    ) throws -> Data {
        guard count >= 0 else {
            throw truncated()
        }
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { bytes in
            while offset < count {
                let result = Darwin.read(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    count - offset
                )
                if result > 0 {
                    offset += result
                } else if result == 0 {
                    throw truncated()
                } else if errno != EINTR {
                    throw SandboxDescriptorIOError.io(errno)
                }
            }
        }
        return data
    }

    static func readUpTo(
        _ maximumCount: Int,
        from descriptor: Int32
    ) throws -> Data {
        guard maximumCount >= 0 else {
            throw SandboxDescriptorIOError.io(EINVAL)
        }
        var data = Data()
        data.reserveCapacity(maximumCount)
        var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumCount))
        while data.count < maximumCount {
            let requested = min(buffer.count, maximumCount - data.count)
            let result = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, requested)
            }
            if result > 0 {
                data.append(contentsOf: buffer[0..<result])
            } else if result == 0 {
                break
            } else if errno != EINTR {
                throw SandboxDescriptorIOError.io(errno)
            }
        }
        return data
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < data.count {
                let result = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    data.count - offset
                )
                if result > 0 {
                    offset += result
                } else if result == 0 {
                    throw SandboxDescriptorIOError.io(EIO)
                } else if errno != EINTR {
                    throw SandboxDescriptorIOError.io(errno)
                }
            }
        }
    }
}

private final class StableSource {
    let descriptor: Int32
    let metadata: stat

    private var isClosed = false

    init(_ source: URL) throws {
        guard source.isFileURL,
              source.baseURL == nil,
              source.path.hasPrefix("/"),
              !source.path.contains("\0"),
              SandboxDescriptorPathPolicy.isAccepted(source)
        else {
            throw SandboxDescriptorIOError.sourceNotRegularFile
        }
        let descriptor = Darwin.open(
            source.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw SandboxDescriptorIOError.sourceNotRegularFile
            }
            throw SandboxDescriptorIOError.io(errno)
        }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw SandboxDescriptorIOError.io(code)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0
        else {
            Darwin.close(descriptor)
            throw SandboxDescriptorIOError.sourceNotRegularFile
        }
        self.descriptor = descriptor
        self.metadata = metadata
    }

    func requireUnchanged() throws {
        var current = stat()
        guard fstat(descriptor, &current) == 0,
              Self.matches(metadata, current)
        else {
            throw SandboxDescriptorIOError.sourceChanged
        }
    }

    func close() {
        guard !isClosed else {
            return
        }
        isClosed = true
        Darwin.close(descriptor)
    }

    private static func matches(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_uid == rhs.st_uid
            && lhs.st_gid == rhs.st_gid
            && lhs.st_rdev == rhs.st_rdev
            && lhs.st_size == rhs.st_size
            && lhs.st_flags == rhs.st_flags
            && lhs.st_gen == rhs.st_gen
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

private final class PendingDestination {
    let descriptor: Int32

    private let parentDescriptor: Int32
    private let temporaryName: String
    private let destinationName: String
    private var destinationDescriptor: Int32
    private var synchronizedMetadata: stat?
    private var isPublished = false

    init(_ destination: URL) throws {
        guard destination.isFileURL,
              destination.baseURL == nil,
              destination.path.hasPrefix("/"),
              !destination.hasDirectoryPath,
              !destination.path.contains("\0")
        else {
            throw SandboxDescriptorIOError.unsafeDestination
        }
        let destinationName = destination.lastPathComponent
        guard !destinationName.isEmpty,
              destinationName != ".",
              destinationName != "..",
              !destinationName.contains("/")
        else {
            throw SandboxDescriptorIOError.unsafeDestination
        }

        let parent = destination.deletingLastPathComponent()
        guard SandboxDescriptorPathPolicy.isAccepted(parent) else {
            throw SandboxDescriptorIOError.unsafeDestination
        }
        var pathMetadata = stat()
        guard lstat(parent.path, &pathMetadata) == 0,
              (pathMetadata.st_mode & S_IFMT) == S_IFDIR
        else {
            throw SandboxDescriptorIOError.unsafeDestination
        }
        let canonicalParent = parent.resolvingSymlinksInPath()
        let parentDescriptor = Darwin.open(
            canonicalParent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else {
            throw SandboxDescriptorIOError.io(errno)
        }
        var descriptorMetadata = stat()
        guard fstat(parentDescriptor, &descriptorMetadata) == 0,
              (descriptorMetadata.st_mode & S_IFMT) == S_IFDIR,
              descriptorMetadata.st_dev == pathMetadata.st_dev,
              descriptorMetadata.st_ino == pathMetadata.st_ino
        else {
            Darwin.close(parentDescriptor)
            throw SandboxDescriptorIOError.unsafeDestination
        }

        let temporaryName = ".\(destinationName).\(UUID().uuidString.lowercased()).partial"
        let destinationDescriptor = temporaryName.withCString {
            openat(
                parentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard destinationDescriptor >= 0 else {
            let code = errno
            Darwin.close(parentDescriptor)
            throw SandboxDescriptorIOError.io(code)
        }
        var temporaryMetadata = stat()
        guard fstat(destinationDescriptor, &temporaryMetadata) == 0,
              (temporaryMetadata.st_mode & S_IFMT) == S_IFREG,
              temporaryMetadata.st_uid == geteuid(),
              temporaryMetadata.st_nlink == 1,
              temporaryMetadata.st_mode & 0o077 == 0
        else {
            Darwin.close(destinationDescriptor)
            temporaryName.withCString {
                _ = unlinkat(parentDescriptor, $0, 0)
            }
            Darwin.close(parentDescriptor)
            throw SandboxDescriptorIOError.unsafeDestination
        }

        self.parentDescriptor = parentDescriptor
        self.temporaryName = temporaryName
        self.destinationName = destinationName
        self.destinationDescriptor = destinationDescriptor
        self.descriptor = destinationDescriptor
    }

    func synchronize() throws {
        guard destinationDescriptor >= 0 else {
            throw SandboxDescriptorIOError.io(EBADF)
        }
        guard fsync(destinationDescriptor) == 0 else {
            throw SandboxDescriptorIOError.io(errno)
        }
        var metadata = stat()
        guard fstat(destinationDescriptor, &metadata) == 0,
              Self.isSafeTemporary(metadata)
        else {
            throw SandboxDescriptorIOError.unsafeDestination
        }
        synchronizedMetadata = metadata
    }

    func publish() throws {
        guard destinationDescriptor >= 0,
              let synchronizedMetadata
        else {
            throw SandboxDescriptorIOError.io(EBADF)
        }
        var namedMetadata = stat()
        let namedResult = temporaryName.withCString {
            fstatat(
                parentDescriptor,
                $0,
                &namedMetadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard namedResult == 0,
              Self.matches(synchronizedMetadata, namedMetadata)
        else {
            throw SandboxDescriptorIOError.unsafeDestination
        }
        let result = temporaryName.withCString { temporary in
            destinationName.withCString { destination in
                renameatx_np(
                    parentDescriptor,
                    temporary,
                    parentDescriptor,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            if errno == EEXIST {
                throw SandboxDescriptorIOError.destinationExists
            }
            throw SandboxDescriptorIOError.io(errno)
        }

        var descriptorMetadata = stat()
        var publishedMetadata = stat()
        let publishedResult = destinationName.withCString {
            fstatat(
                parentDescriptor,
                $0,
                &publishedMetadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard fstat(destinationDescriptor, &descriptorMetadata) == 0,
              publishedResult == 0,
              Self.matches(synchronizedMetadata, descriptorMetadata),
              Self.matches(synchronizedMetadata, publishedMetadata)
        else {
            if publishedResult == 0,
               publishedMetadata.st_dev == synchronizedMetadata.st_dev,
               publishedMetadata.st_ino == synchronizedMetadata.st_ino
            {
                destinationName.withCString {
                    _ = unlinkat(parentDescriptor, $0, 0)
                }
            }
            throw SandboxDescriptorIOError.unsafeDestination
        }
        isPublished = true
        Darwin.close(destinationDescriptor)
        destinationDescriptor = -1
        guard fsync(parentDescriptor) == 0 else {
            throw SandboxDescriptorIOError.io(errno)
        }
    }

    func cleanup() {
        if destinationDescriptor >= 0 {
            Darwin.close(destinationDescriptor)
            destinationDescriptor = -1
        }
        if !isPublished {
            temporaryName.withCString {
                _ = unlinkat(parentDescriptor, $0, 0)
            }
        }
        Darwin.close(parentDescriptor)
    }

    private static func isSafeTemporary(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_uid == geteuid()
            && metadata.st_nlink == 1
            && metadata.st_mode & 0o077 == 0
    }

    private static func matches(_ expected: stat, _ actual: stat) -> Bool {
        isSafeTemporary(actual)
            && expected.st_dev == actual.st_dev
            && expected.st_ino == actual.st_ino
            && expected.st_mode == actual.st_mode
            && expected.st_uid == actual.st_uid
            && expected.st_gid == actual.st_gid
            && expected.st_nlink == actual.st_nlink
            && expected.st_size == actual.st_size
            && expected.st_flags == actual.st_flags
            && expected.st_gen == actual.st_gen
    }
}

private enum SandboxDescriptorPathPolicy {
    static func isAccepted(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL.path
        guard standardized == url.path else {
            return false
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        if resolved == standardized {
            return true
        }
        for alias in ["/tmp", "/var"] {
            if standardized == alias || standardized.hasPrefix(alias + "/") {
                return resolved == "/private" + standardized
            }
        }
        return false
    }
}
