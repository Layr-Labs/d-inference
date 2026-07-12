import Foundation

#if canImport(Darwin)
import Darwin
#endif

public enum FanDurableFileError: Error, CustomStringConvertible {
    case unsafeFile(String)
    case tooLarge(String)
    case systemCall(String, Int32)

    public var description: String {
        switch self {
        case .unsafeFile(let detail): return detail
        case .tooLarge(let path): return "fan state file is too large: \(path)"
        case .systemCall(let call, let code): return "\(call) failed (errno \(code))"
        }
    }
}

public enum FanDurableFile {
    private static let maximumBytes = 64 * 1024

    public static func readJSON<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        requireRootOwnership: Bool = true
    ) throws -> T {
        #if canImport(Darwin)
        let directory = url.deletingLastPathComponent()
        let directoryDescriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw FanDurableFileError.systemCall("open state directory", errno)
        }
        defer { Darwin.close(directoryDescriptor) }
        let descriptor = openat(
            directoryDescriptor,
            url.lastPathComponent,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw FanDurableFileError.systemCall("open state file", errno)
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            Darwin.close(descriptor)
            throw FanDurableFileError.systemCall("fstat", errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw FanDurableFileError.unsafeFile(
                "fan state must be a regular file: \(url.path)"
            )
        }
        if requireRootOwnership {
            guard metadata.st_uid == 0 else {
                Darwin.close(descriptor)
                throw FanDurableFileError.unsafeFile(
                    "fan state is not root-owned: \(url.path)"
                )
            }
            guard metadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
                Darwin.close(descriptor)
                throw FanDurableFileError.unsafeFile(
                    "fan state is group/world-writable: \(url.path)"
                )
            }
        }
        guard metadata.st_size <= maximumBytes else {
            Darwin.close(descriptor)
            throw FanDurableFileError.tooLarge(url.path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        try handle.close()
        guard data.count <= maximumBytes else {
            throw FanDurableFileError.tooLarge(url.path)
        }
        #else
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        #endif
        guard data.count <= maximumBytes else {
            throw FanDurableFileError.tooLarge(url.path)
        }
        return try JSONDecoder().decode(type, from: data)
    }

    public static func writeJSON<T: Encodable>(
        _ value: T,
        to url: URL,
        permissions: mode_t,
        owner: (uid: uid_t, gid: gid_t)? = (0, 0)
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else {
            throw FanDurableFileError.tooLarge(url.path)
        }
        try write(
            data,
            to: url,
            permissions: permissions,
            owner: owner
        )
    }

    public static func writeData(
        _ data: Data,
        to url: URL,
        permissions: mode_t,
        owner: (uid: uid_t, gid: gid_t)? = (0, 0)
    ) throws {
        guard data.count <= maximumBytes else {
            throw FanDurableFileError.tooLarge(url.path)
        }
        try write(
            data,
            to: url,
            permissions: permissions,
            owner: owner
        )
    }

    public static func remove(_ url: URL) throws {
        #if canImport(Darwin)
        let directory = url.deletingLastPathComponent()
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0, errno == ENOENT { return }
        guard descriptor >= 0 else {
            throw FanDurableFileError.systemCall("open remove directory", errno)
        }
        defer { Darwin.close(descriptor) }
        if unlinkat(descriptor, url.lastPathComponent, 0) != 0, errno != ENOENT {
            throw FanDurableFileError.systemCall("unlinkat", errno)
        }
        guard fsync(descriptor) == 0 else {
            throw FanDurableFileError.systemCall("fsync directory", errno)
        }
        #else
        try? FileManager.default.removeItem(at: url)
        #endif
    }

    private static func write(
        _ data: Data,
        to url: URL,
        permissions: mode_t,
        owner: (uid: uid_t, gid: gid_t)?
    ) throws {
        let directory = url.deletingLastPathComponent()

        #if canImport(Darwin)
        var directoryMetadata = stat()
        if lstat(directory.path, &directoryMetadata) != 0 {
            guard errno == ENOENT else {
                throw FanDurableFileError.systemCall("lstat directory", errno)
            }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } else if directoryMetadata.st_mode & S_IFMT != S_IFDIR {
            throw FanDurableFileError.unsafeFile(
                "fan state parent must be a non-symlink directory: \(directory.path)"
            )
        }
        guard lstat(directory.path, &directoryMetadata) == 0,
              directoryMetadata.st_mode & S_IFMT == S_IFDIR
        else {
            throw FanDurableFileError.unsafeFile(
                "fan state parent is unsafe: \(directory.path)"
            )
        }
        if owner != nil {
            guard directoryMetadata.st_uid == 0,
                  directoryMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0
            else {
                throw FanDurableFileError.unsafeFile(
                    "fan state parent is not a root-only directory: \(directory.path)"
                )
            }
        }
        let directoryDescriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw FanDurableFileError.systemCall("open state directory", errno)
        }
        defer { Darwin.close(directoryDescriptor) }
        guard fstat(directoryDescriptor, &directoryMetadata) == 0,
              directoryMetadata.st_mode & S_IFMT == S_IFDIR
        else {
            throw FanDurableFileError.unsafeFile(
                "fan state directory changed during validation: \(directory.path)"
            )
        }
        let temporaryName = ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        let descriptor = openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            permissions
        )
        guard descriptor >= 0 else {
            throw FanDurableFileError.systemCall("open", errno)
        }
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(descriptor)
            if shouldRemoveTemporary {
                _ = unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    rawBuffer.baseAddress!.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw FanDurableFileError.systemCall("write", errno)
                }
                offset += written
            }
        }
        guard fchmod(descriptor, permissions) == 0 else {
            throw FanDurableFileError.systemCall("fchmod", errno)
        }
        if let owner {
            guard fchown(descriptor, owner.uid, owner.gid) == 0 else {
                throw FanDurableFileError.systemCall("fchown", errno)
            }
        }
        guard fsync(descriptor) == 0 else {
            throw FanDurableFileError.systemCall("fsync", errno)
        }
        guard renameat(
            directoryDescriptor,
            temporaryName,
            directoryDescriptor,
            url.lastPathComponent
        ) == 0 else {
            throw FanDurableFileError.systemCall("renameat", errno)
        }
        shouldRemoveTemporary = false
        guard fsync(directoryDescriptor) == 0 else {
            throw FanDurableFileError.systemCall("fsync directory", errno)
        }
        #else
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        #endif
    }

}
