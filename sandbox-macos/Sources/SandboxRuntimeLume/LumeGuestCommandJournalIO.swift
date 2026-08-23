import Darwin
import Foundation
import SandboxRuntime

enum LumeGuestCommandJournalIO {
    static func openPrivateDirectory(_ url: URL) throws -> Int32 {
        let descriptor = open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw ioFailure("guest command journal is unavailable")
        }
        do {
            try requirePrivateDirectory(descriptor)
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func openOrCreatePrivateDirectory(
        parentDescriptor: Int32,
        name: String
    ) throws -> Int32 {
        if mkdirat(parentDescriptor, name, 0o700) != 0, errno != EEXIST {
            throw ioFailure("failed to create guest command journal directory")
        }
        return try openRequiredDirectory(
            parentDescriptor: parentDescriptor,
            name: name
        )
    }

    static func openDirectoryIfPresent(
        parentDescriptor: Int32,
        name: String
    ) throws -> Int32? {
        let descriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return nil
            }
            throw ioFailure("guest command journal path is unsafe")
        }
        do {
            try requirePrivateDirectory(descriptor)
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func openRequiredDirectory(
        parentDescriptor: Int32,
        name: String
    ) throws -> Int32 {
        guard let descriptor = try openDirectoryIfPresent(
            parentDescriptor: parentDescriptor,
            name: name
        ) else {
            throw ioFailure("guest command journal directory disappeared")
        }
        return descriptor
    }

    static func writeExclusive(
        _ data: Data,
        named name: String,
        parentDescriptor: Int32
    ) throws {
        let descriptor = openat(
            parentDescriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw ioFailure("failed to persist guest command claim")
        }
        defer { close(descriptor) }
        try writeAll(data, descriptor: descriptor)
        guard fsync(descriptor) == 0 else {
            throw ioFailure("failed to synchronize guest command claim")
        }
    }

    static func publishResult(
        _ envelope: Data,
        commandDescriptor: Int32
    ) throws {
        guard !envelope.isEmpty,
              envelope.count <= LumeGuestCommandEnvelope.maximumEnvelopeBytes
        else {
            throw SandboxRuntimeError.malformedOutput(
                "guest command journal result exceeds its bound"
            )
        }
        _ = try LumeGuestCommandResultDecoder.decode(envelope)
        let temporaryName = ".result-\(UUID().uuidString.lowercased()).partial"
        let temporaryDescriptor = openat(
            commandDescriptor,
            temporaryName,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard temporaryDescriptor >= 0 else {
            throw ioFailure("failed to stage guest command result")
        }
        var temporaryIsLinked = true
        defer {
            close(temporaryDescriptor)
            if temporaryIsLinked {
                unlinkat(commandDescriptor, temporaryName, 0)
            }
        }
        guard unlinkat(commandDescriptor, temporaryName, 0) == 0 else {
            throw ioFailure("failed to unlink staged guest command result")
        }
        temporaryIsLinked = false
        try writeAll(envelope, descriptor: temporaryDescriptor)
        guard fsync(temporaryDescriptor) == 0 else {
            throw ioFailure("failed to synchronize guest command result")
        }
        let cloneStatus =
            LumeGuestCommandJournal.resultFileName.withCString { destination in
                fclonefileat(
                    temporaryDescriptor,
                    commandDescriptor,
                    destination,
                    UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)
                )
            }
        guard cloneStatus == 0 else {
            if errno == EEXIST,
               let existing = try readFileIfPresent(
                   named: LumeGuestCommandJournal.resultFileName,
                   parentDescriptor: commandDescriptor,
                   maximumBytes: LumeGuestCommandEnvelope.maximumEnvelopeBytes
               ),
               existing == envelope
            {
                return
            }
            throw ioFailure("failed to publish guest command result")
        }
        guard let committed = try readFileIfPresent(
            named: LumeGuestCommandJournal.resultFileName,
            parentDescriptor: commandDescriptor,
            maximumBytes: LumeGuestCommandEnvelope.maximumEnvelopeBytes
        ), committed == envelope,
              fsync(commandDescriptor) == 0
        else {
            throw ioFailure("guest command result publication is uncertain")
        }
    }

    static func readFileIfPresent(
        named name: String,
        parentDescriptor: Int32,
        maximumBytes: Int
    ) throws -> Data? {
        let descriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return nil
            }
            throw ioFailure("guest command journal file is unsafe")
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0,
              metadata.st_size >= 0,
              metadata.st_size <= maximumBytes
        else {
            throw SandboxRuntimeError.unsupported(
                "guest command journal file failed ownership, type, mode, or size checks"
            )
        }
        var data = Data(count: Int(metadata.st_size))
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
                    throw ioFailure(
                        "guest command journal file changed while reading"
                    )
                }
                offset += count
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              after.st_dev == metadata.st_dev,
              after.st_ino == metadata.st_ino,
              after.st_size == metadata.st_size,
              after.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == metadata.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == metadata.st_ctimespec.tv_nsec
        else {
            throw ioFailure(
                "guest command journal file changed while reading"
            )
        }
        return data
    }

    static func ioFailure(_ detail: String) -> SandboxRuntimeError {
        .unsupported("\(detail) (errno \(errno))")
    }

    private static func requirePrivateDirectory(
        _ descriptor: Int32
    ) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0
        else {
            throw SandboxRuntimeError.unsupported(
                "guest command journal directory failed ownership or mode checks"
            )
        }
    }

    private static func writeAll(
        _ data: Data,
        descriptor: Int32
    ) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
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
                    throw ioFailure("guest command journal write failed")
                }
                offset += count
            }
        }
    }
}
