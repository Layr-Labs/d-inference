import CryptoKit
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

    static func withExclusiveDestination(
        at destination: URL,
        _ operation: (Int32) throws -> Data
    ) throws {
        let pending = try PendingDestination(destination)
        defer { pending.cleanup() }

        let expectedSHA256 = try operation(pending.descriptor)
        try pending.synchronize(expectedSHA256: expectedSHA256)
        try pending.publish(expectedSHA256: expectedSHA256)
    }

    static func withStableSourceAndExclusiveDestination(
        source: URL,
        destination: URL,
        _ operation: (
            Int32,
            stat,
            Int32
        ) throws -> Data
    ) throws {
        let openedSource = try StableSource(source)
        defer { openedSource.close() }
        let pending = try PendingDestination(destination)
        defer { pending.cleanup() }

        let expectedSHA256: Data
        do {
            expectedSHA256 = try operation(
                openedSource.descriptor,
                openedSource.metadata,
                pending.descriptor
            )
            try pending.synchronize(expectedSHA256: expectedSHA256)
        } catch {
            try openedSource.requireUnchanged()
            throw error
        }
        try openedSource.requireUnchanged()
        try pending.publish(expectedSHA256: expectedSHA256)
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

    private let source: URL
    private let canonicalPath: String
    private var isClosed = false

    init(_ source: URL) throws {
        guard source.isFileURL,
              source.baseURL == nil,
              source.path.hasPrefix("/"),
              !source.path.contains("\0"),
              let canonicalPath = SandboxDescriptorPathPolicy.canonicalPath(
                  for: source
              )
        else {
            throw SandboxDescriptorIOError.sourceNotRegularFile
        }
        let descriptor = try SandboxDescriptorPathPolicy.openFile(
            canonicalPath,
            flags: O_RDONLY | O_NONBLOCK
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
        self.source = source
        self.canonicalPath = canonicalPath
        self.descriptor = descriptor
        self.metadata = metadata
    }

    func requireUnchanged() throws {
        var current = stat()
        guard fstat(descriptor, &current) == 0,
              Self.matches(metadata, current),
              SandboxDescriptorPathPolicy.canonicalPath(for: source)
                  == canonicalPath
        else {
            throw SandboxDescriptorIOError.sourceChanged
        }
        let rebound = try SandboxDescriptorPathPolicy.openFile(
            canonicalPath,
            flags: O_RDONLY | O_NONBLOCK
        )
        defer { Darwin.close(rebound) }
        var reboundMetadata = stat()
        guard fstat(rebound, &reboundMetadata) == 0,
              reboundMetadata.st_dev == metadata.st_dev,
              reboundMetadata.st_ino == metadata.st_ino
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
    private let parent: URL
    private let canonicalParentPath: String
    private let parentDevice: dev_t
    private let parentInode: ino_t
    private let temporaryName: String
    private let destinationName: String
    private var destinationDescriptor: Int32
    private var synchronizedMetadata: stat?
    private var publishedCandidate = false
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
        guard let canonicalParentPath =
            SandboxDescriptorPathPolicy.canonicalPath(for: parent)
        else {
            throw SandboxDescriptorIOError.unsafeDestination
        }
        var pathMetadata = stat()
        guard lstat(parent.path, &pathMetadata) == 0,
              (pathMetadata.st_mode & S_IFMT) == S_IFDIR
        else {
            throw SandboxDescriptorIOError.unsafeDestination
        }
        let parentDescriptor = try SandboxDescriptorPathPolicy.openDirectory(
            canonicalParentPath
        )
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
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
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
        self.parent = parent
        self.canonicalParentPath = canonicalParentPath
        self.parentDevice = descriptorMetadata.st_dev
        self.parentInode = descriptorMetadata.st_ino
        self.temporaryName = temporaryName
        self.destinationName = destinationName
        self.destinationDescriptor = destinationDescriptor
        self.descriptor = destinationDescriptor
    }

    func synchronize(expectedSHA256: Data) throws {
        guard destinationDescriptor >= 0 else {
            throw SandboxDescriptorIOError.io(EBADF)
        }
        try requireContentSHA256(expectedSHA256)
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

    func publish(expectedSHA256: Data) throws {
        guard destinationDescriptor >= 0,
              let synchronizedMetadata
        else {
            throw SandboxDescriptorIOError.io(EBADF)
        }
        try requireParentBinding()
        try requireContentSHA256(expectedSHA256)
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
        publishedCandidate = true

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
            removePublishedCandidate(
                observed: publishedResult == 0 ? publishedMetadata : nil
            )
            throw SandboxDescriptorIOError.unsafeDestination
        }
        do {
            try requireContentSHA256(expectedSHA256)
            try requireParentBinding()
        } catch {
            removePublishedCandidate(observed: publishedMetadata)
            throw error
        }
        isPublished = true
        publishedCandidate = false
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
        if publishedCandidate {
            removePublishedCandidate(observed: nil)
        }
        Darwin.close(parentDescriptor)
    }

    private func requireParentBinding() throws {
        guard SandboxDescriptorPathPolicy.canonicalPath(for: parent)
                == canonicalParentPath
        else {
            throw SandboxDescriptorIOError.unsafeDestination
        }
        let rebound = try SandboxDescriptorPathPolicy.openDirectory(
            canonicalParentPath
        )
        defer { Darwin.close(rebound) }
        var metadata = stat()
        guard fstat(rebound, &metadata) == 0,
              metadata.st_dev == parentDevice,
              metadata.st_ino == parentInode
        else {
            throw SandboxDescriptorIOError.unsafeDestination
        }
    }

    private func requireContentSHA256(_ expected: Data) throws {
        guard expected.count == SHA256.byteCount else {
            throw SandboxDescriptorIOError.unsafeDestination
        }
        let actual = try Self.sha256(of: destinationDescriptor)
        guard actual == expected else {
            throw SandboxDescriptorIOError.unsafeDestination
        }
    }

    private func removePublishedCandidate(observed: stat?) {
        var current = stat()
        let result = destinationName.withCString {
            fstatat(
                parentDescriptor,
                $0,
                &current,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard result == 0 else {
            publishedCandidate = false
            return
        }
        if let observed,
           current.st_dev != observed.st_dev || current.st_ino != observed.st_ino
        {
            return
        }
        destinationName.withCString {
            _ = unlinkat(parentDescriptor, $0, 0)
        }
        publishedCandidate = false
    }

    private static func sha256(of descriptor: Int32) throws -> Data {
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_size >= 0
        else {
            throw SandboxDescriptorIOError.unsafeDestination
        }
        var hasher = SHA256()
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while offset < before.st_size {
            let requested = min(
                buffer.count,
                Int(before.st_size - offset)
            )
            let result = buffer.withUnsafeMutableBytes {
                pread(descriptor, $0.baseAddress, requested, offset)
            }
            if result > 0 {
                hasher.update(data: Data(buffer[0..<result]))
                offset += off_t(result)
            } else if result == 0 {
                throw SandboxDescriptorIOError.unsafeDestination
            } else if errno != EINTR {
                throw SandboxDescriptorIOError.io(errno)
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else {
            throw SandboxDescriptorIOError.unsafeDestination
        }
        return Data(hasher.finalize())
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
    static func canonicalPath(for url: URL) -> String? {
        let standardized = url.standardizedFileURL.path
        guard standardized == url.path else {
            return nil
        }
        guard let resolvedPointer = realpath(standardized, nil) else {
            return nil
        }
        defer { free(resolvedPointer) }
        let resolved = String(cString: resolvedPointer)
        if resolved == standardized {
            return resolved
        }
        for alias in ["/tmp", "/var"] {
            if standardized == alias || standardized.hasPrefix(alias + "/") {
                return resolved == "/private" + standardized
                    ? resolved
                    : nil
            }
        }
        return nil
    }

    static func openDirectory(_ canonicalPath: String) throws -> Int32 {
        try openCanonicalPath(canonicalPath, finalFlags: O_DIRECTORY)
    }

    static func openFile(
        _ canonicalPath: String,
        flags: Int32
    ) throws -> Int32 {
        try openCanonicalPath(canonicalPath, finalFlags: flags)
    }

    private static func openCanonicalPath(
        _ canonicalPath: String,
        finalFlags: Int32
    ) throws -> Int32 {
        let components = canonicalPath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.first == "",
              components.count > 1,
              !components.dropFirst().contains(where: {
                  $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("/")
              })
        else {
            throw SandboxDescriptorIOError.unsafeDestination
        }
        var descriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SandboxDescriptorIOError.io(errno)
        }
        for (index, component) in components.dropFirst().enumerated() {
            let isFinal = index == components.count - 2
            let flags = isFinal
                ? finalFlags | O_NOFOLLOW | O_CLOEXEC
                : O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            let next = component.withCString {
                openat(descriptor, $0, flags)
            }
            guard next >= 0 else {
                let code = errno
                Darwin.close(descriptor)
                if code == ELOOP {
                    throw SandboxDescriptorIOError.unsafeDestination
                }
                throw SandboxDescriptorIOError.io(code)
            }
            Darwin.close(descriptor)
            descriptor = next
        }
        return descriptor
    }
}
