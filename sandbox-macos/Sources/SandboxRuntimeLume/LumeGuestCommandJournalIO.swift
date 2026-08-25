import Darwin
import Foundation
import SandboxRuntime

enum LumeGuestCommandJournalIO {
    static func openPrivateDirectory(_ url: URL) throws -> Int32 {
        do {
            return try SandboxAuthorityFileSystem.openPrivateDirectory(
                at: url,
                createIfMissing: false,
                requirePrivateParent: true
            )
        } catch {
            throw ioFailure("guest command journal is unavailable")
        }
    }

    static func openOrCreatePrivateDirectory(
        parentDescriptor: Int32,
        name: String
    ) throws -> Int32 {
        do {
            return try SandboxAuthorityFileSystem.openPrivateChildDirectory(
                parentDescriptor: parentDescriptor,
                name: name,
                createIfMissing: true
            )
        } catch {
            throw ioFailure("failed to create guest command journal directory")
        }
    }

    static func openDirectoryIfPresent(
        parentDescriptor: Int32,
        name: String
    ) throws -> Int32? {
        try requirePrivateDirectory(parentDescriptor)
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
        let descriptor: Int32
        do {
            descriptor = try SandboxAuthorityFileSystem
                .createUnlinkedPrivateFile(
                    parentDescriptor: parentDescriptor,
                    prefix: name
                )
        } catch {
            throw ioFailure("failed to stage guest command claim")
        }
        defer { close(descriptor) }
        try writeAll(data, descriptor: descriptor)
        try synchronize(descriptor, subject: "guest command claim")
        do {
            _ = try SandboxAuthorityFileSystem.requirePrivateRegularFile(
                descriptor,
                maximumBytes: data.count,
                allowEmpty: data.isEmpty,
                expectedLinkCount: 0
            )
        } catch {
            throw ioFailure("guest command claim staging is unsafe")
        }
        let cloneStatus = name.withCString {
            fclonefileat(
                descriptor,
                parentDescriptor,
                $0,
                UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)
            )
        }
        guard cloneStatus == 0 else {
            throw ioFailure("failed to persist guest command claim")
        }
        try synchronizeCommittedFile(
            expected: data,
            named: name,
            parentDescriptor: parentDescriptor,
            maximumBytes: data.count
        )
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
        let temporaryDescriptor: Int32
        do {
            temporaryDescriptor = try SandboxAuthorityFileSystem
                .createUnlinkedPrivateFile(
                    parentDescriptor: commandDescriptor,
                    prefix: "result"
                )
        } catch {
            throw ioFailure("failed to stage guest command result")
        }
        defer { close(temporaryDescriptor) }
        try writeAll(envelope, descriptor: temporaryDescriptor)
        try synchronize(
            temporaryDescriptor,
            subject: "guest command result"
        )
        do {
            _ = try SandboxAuthorityFileSystem.requirePrivateRegularFile(
                temporaryDescriptor,
                maximumBytes: LumeGuestCommandEnvelope.maximumEnvelopeBytes,
                allowEmpty: false,
                expectedLinkCount: 0
            )
        } catch {
            throw ioFailure("guest command result staging is unsafe")
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
                try synchronizeCommittedFile(
                    expected: envelope,
                    named: LumeGuestCommandJournal.resultFileName,
                    parentDescriptor: commandDescriptor,
                    maximumBytes:
                        LumeGuestCommandEnvelope.maximumEnvelopeBytes
                )
                return
            }
            throw ioFailure("failed to publish guest command result")
        }
        try synchronizeCommittedFile(
            expected: envelope,
            named: LumeGuestCommandJournal.resultFileName,
            parentDescriptor: commandDescriptor,
            maximumBytes: LumeGuestCommandEnvelope.maximumEnvelopeBytes
        )
    }

    static func readFileIfPresent(
        named name: String,
        parentDescriptor: Int32,
        maximumBytes: Int,
        synchronizeBeforeReturn: Bool = false
    ) throws -> Data? {
        try requirePrivateDirectory(parentDescriptor)
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
        do {
            let data = try SandboxAuthorityFileSystem.readStablePrivateFile(
                descriptor,
                maximumBytes: maximumBytes,
                allowEmpty: true
            )
            if synchronizeBeforeReturn {
                try synchronize(
                    descriptor,
                    subject: "guest command journal replay file"
                )
                try synchronize(
                    parentDescriptor,
                    subject: "guest command journal replay directory"
                )
            }
            return data
        } catch {
            throw SandboxRuntimeError.unsupported(
                "guest command journal file failed ownership, ACL, link, or stability checks"
            )
        }
    }

    static func ioFailure(_ detail: String) -> SandboxRuntimeError {
        .unsupported("\(detail) (errno \(errno))")
    }

    private static func synchronizeCommittedFile(
        expected: Data,
        named name: String,
        parentDescriptor: Int32,
        maximumBytes: Int
    ) throws {
        try requirePrivateDirectory(parentDescriptor)
        let descriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw ioFailure("committed guest command journal file is unavailable")
        }
        defer { close(descriptor) }
        let committed: Data
        do {
            committed =
                try SandboxAuthorityFileSystem.readStablePrivateFile(
                    descriptor,
                    maximumBytes: maximumBytes,
                    allowEmpty: expected.isEmpty
                )
        } catch {
            throw ioFailure("committed guest command journal file is unsafe")
        }
        guard committed == expected else {
            throw ioFailure("guest command journal publication is uncertain")
        }
        try synchronize(
            descriptor,
            subject: "committed guest command journal file"
        )
        try synchronize(
            parentDescriptor,
            subject: "guest command journal directory"
        )
    }

    private static func requirePrivateDirectory(
        _ descriptor: Int32
    ) throws {
        do {
            try SandboxAuthorityFileSystem.requirePrivateDirectory(descriptor)
        } catch {
            throw SandboxRuntimeError.unsupported(
                "guest command journal directory failed ownership, mode, or ACL checks"
            )
        }
    }

    static func synchronize(
        _ descriptor: Int32,
        subject: String
    ) throws {
        do {
            try SandboxAuthorityFileSystem.synchronize(descriptor)
        } catch {
            throw ioFailure("failed to synchronize \(subject)")
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
