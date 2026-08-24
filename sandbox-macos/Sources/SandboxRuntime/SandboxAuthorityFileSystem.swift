import Darwin
import Foundation

package enum SandboxAuthorityFileSystemError: Error, Equatable {
    case unsafePath
    case io(Int32)
    case publicationUncertain(Int32)
}

package enum SandboxAuthorityFileSystem {
    package static func openPrivateDirectory(
        at url: URL,
        createIfMissing: Bool,
        requirePrivateParent: Bool = false
    ) throws -> Int32 {
        let parent = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        guard isSafeComponent(name),
              url.standardizedFileURL.path == url.path
        else {
            throw SandboxAuthorityFileSystemError.unsafePath
        }
        let parentDescriptor = try openExistingDirectory(at: parent)
        defer { close(parentDescriptor) }
        if requirePrivateParent {
            try requirePrivateDirectory(parentDescriptor)
        }

        var created = false
        if createIfMissing {
            if mkdirat(parentDescriptor, name, 0o700) == 0 {
                created = true
            } else if errno != EEXIST {
                throw pathError(errno)
            }
        }
        let descriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw pathError(errno)
        }
        do {
            try requirePrivateDirectory(descriptor)
            if created {
                do {
                    try synchronize(parentDescriptor)
                } catch {
                    throw publicationError(error)
                }
            }
            return descriptor
        } catch {
            close(descriptor)
            if created {
                _ = unlinkat(parentDescriptor, name, AT_REMOVEDIR)
            }
            throw error
        }
    }

    package static func openPrivateChildDirectory(
        parentDescriptor: Int32,
        name: String,
        createIfMissing: Bool
    ) throws -> Int32 {
        guard isSafeComponent(name) else {
            throw SandboxAuthorityFileSystemError.unsafePath
        }
        try requirePrivateDirectory(parentDescriptor)
        var created = false
        if createIfMissing {
            if mkdirat(parentDescriptor, name, 0o700) == 0 {
                created = true
            } else if errno != EEXIST {
                throw pathError(errno)
            }
        }
        let descriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw pathError(errno)
        }
        do {
            try requirePrivateDirectory(descriptor)
            if created {
                do {
                    try synchronize(parentDescriptor)
                } catch {
                    throw publicationError(error)
                }
            }
            return descriptor
        } catch {
            close(descriptor)
            if created {
                _ = unlinkat(parentDescriptor, name, AT_REMOVEDIR)
            }
            throw error
        }
    }

    package static func openExistingDirectory(at url: URL) throws -> Int32 {
        guard let canonicalPath = canonicalPath(for: url) else {
            throw SandboxAuthorityFileSystemError.unsafePath
        }
        if canonicalPath == "/" {
            let descriptor = open(
                "/",
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard descriptor >= 0 else {
                throw SandboxAuthorityFileSystemError.io(errno)
            }
            do {
                try requireTrustedAncestorDirectory(descriptor)
                return descriptor
            } catch {
                close(descriptor)
                throw error
            }
        }
        let components = canonicalPath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.first == "",
              components.count > 1,
              !components.dropFirst().contains(where: {
                  !isSafeComponent($0)
              })
        else {
            throw SandboxAuthorityFileSystemError.unsafePath
        }

        var descriptor = open(
            "/",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw SandboxAuthorityFileSystemError.io(errno)
        }
        do {
            try requireTrustedAncestorDirectory(descriptor)
        } catch {
            close(descriptor)
            throw error
        }
        for component in components.dropFirst() {
            let next = openat(
                descriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard next >= 0 else {
                let code = errno
                close(descriptor)
                throw pathError(code)
            }
            do {
                try requireTrustedAncestorDirectory(next)
            } catch {
                close(next)
                close(descriptor)
                throw error
            }
            close(descriptor)
            descriptor = next
        }
        return descriptor
    }

    package static func requirePrivateDirectory(_ descriptor: Int32) throws {
        let metadata = try fileMetadata(descriptor)
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o700 == 0o700,
              metadata.st_mode & 0o077 == 0
        else {
            throw SandboxAuthorityFileSystemError.unsafePath
        }
        try requireNoExtendedACL(descriptor)
    }

    package static func requireOwnedDirectoryWithoutWriteSharing(
        _ descriptor: Int32
    ) throws {
        let metadata = try fileMetadata(descriptor)
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o700 == 0o700,
              metadata.st_mode & 0o022 == 0
        else {
            throw SandboxAuthorityFileSystemError.unsafePath
        }
        try requireNoExtendedACL(descriptor)
    }

    package static func requireTrustedAncestorDirectory(
        _ descriptor: Int32
    ) throws {
        let metadata = try fileMetadata(descriptor)
        let ownerIsTrusted =
            metadata.st_uid == 0 || metadata.st_uid == geteuid()
        let sharedWrite = metadata.st_mode & 0o022 != 0
        let protectedSystemTemporaryDirectory =
            metadata.st_uid == 0 && metadata.st_mode & mode_t(S_ISTXT) != 0
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
              ownerIsTrusted,
              metadata.st_mode & 0o100 != 0,
              !sharedWrite || protectedSystemTemporaryDirectory
        else {
            throw SandboxAuthorityFileSystemError.unsafePath
        }
        try requireNoExtendedACL(descriptor)
    }

    package static func requirePrivateRegularFile(
        _ descriptor: Int32,
        maximumBytes: Int? = nil,
        allowEmpty: Bool = true,
        expectedLinkCount: nlink_t = 1
    ) throws -> stat {
        let metadata = try fileMetadata(descriptor)
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0,
              metadata.st_nlink == expectedLinkCount,
              metadata.st_size >= 0,
              allowEmpty || metadata.st_size > 0,
              maximumBytes.map({ metadata.st_size <= off_t($0) }) ?? true
        else {
            throw SandboxAuthorityFileSystemError.unsafePath
        }
        try requireNoExtendedACL(descriptor)
        return metadata
    }

    package static func requireNoExtendedACL(_ descriptor: Int32) throws {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT {
                return
            }
            throw SandboxAuthorityFileSystemError.io(errno)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        throw SandboxAuthorityFileSystemError.unsafePath
    }

    package static func readStablePrivateFile(
        _ descriptor: Int32,
        maximumBytes: Int,
        allowEmpty: Bool = false
    ) throws -> Data {
        let before = try requirePrivateRegularFile(
            descriptor,
            maximumBytes: maximumBytes,
            allowEmpty: allowEmpty
        )
        var data = Data(count: Int(before.st_size))
        var offset = 0
        try data.withUnsafeMutableBytes { bytes in
            while offset < bytes.count {
                let count = pread(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset,
                    off_t(offset)
                )
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw SandboxAuthorityFileSystemError.io(
                        count == 0 ? EIO : errno
                    )
                }
                offset += count
            }
        }
        let after = try requirePrivateRegularFile(
            descriptor,
            maximumBytes: maximumBytes,
            allowEmpty: allowEmpty
        )
        guard stableIdentity(before, after) else {
            throw SandboxAuthorityFileSystemError.unsafePath
        }
        return data
    }

    package static func createUnlinkedPrivateFile(
        parentDescriptor: Int32,
        prefix: String
    ) throws -> Int32 {
        try requirePrivateDirectory(parentDescriptor)
        guard !prefix.isEmpty,
              !prefix.contains("/"),
              !prefix.contains("\0")
        else {
            throw SandboxAuthorityFileSystemError.unsafePath
        }
        let temporaryName = ".\(prefix)-\(UUID().uuidString.lowercased()).partial"
        let descriptor = openat(
            parentDescriptor,
            temporaryName,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw pathError(errno)
        }
        do {
            _ = try requirePrivateRegularFile(
                descriptor,
                expectedLinkCount: 1
            )
            guard unlinkat(parentDescriptor, temporaryName, 0) == 0 else {
                throw SandboxAuthorityFileSystemError.io(errno)
            }
            _ = try requirePrivateRegularFile(
                descriptor,
                expectedLinkCount: 0
            )
            return descriptor
        } catch {
            close(descriptor)
            _ = unlinkat(parentDescriptor, temporaryName, 0)
            throw error
        }
    }

    package static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw SandboxAuthorityFileSystemError.io(
                        count == 0 ? EIO : errno
                    )
                }
                offset += count
            }
        }
    }

    package static func synchronize(_ descriptor: Int32) throws {
        while fsync(descriptor) != 0 {
            guard errno == EINTR else {
                throw SandboxAuthorityFileSystemError.io(errno)
            }
        }
    }

    package static func fileMetadata(_ descriptor: Int32) throws -> stat {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw SandboxAuthorityFileSystemError.io(errno)
        }
        return metadata
    }

    package static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    package static func stableIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        sameIdentity(lhs, rhs)
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_uid == rhs.st_uid
            && lhs.st_gid == rhs.st_gid
            && lhs.st_size == rhs.st_size
            && lhs.st_flags == rhs.st_flags
            && lhs.st_gen == rhs.st_gen
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    package static func canonicalPath(for url: URL) -> String? {
        guard url.isFileURL,
              url.baseURL == nil,
              url.path.hasPrefix("/"),
              !url.path.contains("\0")
        else {
            return nil
        }
        let standardized = url.standardizedFileURL.path
        guard standardized == url.path,
              let resolvedPointer = realpath(standardized, nil)
        else {
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

    private static func isSafeComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component != "."
            && component != ".."
            && !component.contains("/")
            && !component.contains("\0")
    }

    private static func pathError(
        _ code: Int32
    ) -> SandboxAuthorityFileSystemError {
        switch code {
        case ELOOP, ENOTDIR:
            .unsafePath
        default:
            .io(code)
        }
    }

    private static func publicationError(
        _ error: Error
    ) -> SandboxAuthorityFileSystemError {
        guard let error = error as? SandboxAuthorityFileSystemError,
              case .io(let code) = error
        else {
            return .publicationUncertain(EIO)
        }
        return .publicationUncertain(code)
    }
}
