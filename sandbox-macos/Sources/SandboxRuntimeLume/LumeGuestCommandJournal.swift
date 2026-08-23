import CryptoKit
import Darwin
import Foundation
import SandboxRuntime

struct LumeGuestCommandJournal {
    private static let commitmentFileName = "request.sha256"
    private static let resultFileName = "result.json"
    private static let commitmentByteCount = SHA256.byteCount * 2

    private let workspace: LumeRuntimeWorkspace

    init(workspace: LumeRuntimeWorkspace) {
        self.workspace = workspace
    }

    func replay(
        installationID: UUID,
        request: SandboxGuestCommandRequest
    ) throws -> SandboxGuestCommandResult? {
        try workspace.prepare()
        let rootDescriptor = try Self.openPrivateDirectory(
            workspace.commandJournalDirectory
        )
        defer { close(rootDescriptor) }
        let installationName = installationID.uuidString.lowercased()
        guard let installationDescriptor = try Self.openDirectoryIfPresent(
            parentDescriptor: rootDescriptor,
            name: installationName
        ) else {
            return nil
        }
        defer { close(installationDescriptor) }
        let commandName = LumeGuestCommandIdentity.identifier(
            for: request.idempotencyKey
        )
        guard let commandDescriptor = try Self.openDirectoryIfPresent(
            parentDescriptor: installationDescriptor,
            name: commandName
        ) else {
            return nil
        }
        defer { close(commandDescriptor) }

        try Self.requireMatchingCommitment(
            request,
            commandDescriptor: commandDescriptor
        )
        guard let envelope = try Self.readFileIfPresent(
            named: Self.resultFileName,
            parentDescriptor: commandDescriptor,
            maximumBytes: LumeGuestCommandEnvelope.maximumEnvelopeBytes
        ) else {
            throw Self.outcomeUnavailable()
        }
        return try LumeGuestCommandResultDecoder.decode(envelope)
    }

    func claim(
        installationID: UUID,
        request: SandboxGuestCommandRequest
    ) throws -> LumeGuestCommandClaim {
        try workspace.prepare()
        let rootDescriptor = try Self.openPrivateDirectory(
            workspace.commandJournalDirectory
        )
        defer { close(rootDescriptor) }
        let installationDescriptor = try Self.openOrCreatePrivateDirectory(
            parentDescriptor: rootDescriptor,
            name: installationID.uuidString.lowercased()
        )
        defer { close(installationDescriptor) }
        let commandName = LumeGuestCommandIdentity.identifier(
            for: request.idempotencyKey
        )
        guard mkdirat(installationDescriptor, commandName, 0o700) == 0 else {
            if errno == EEXIST {
                let commandDescriptor = try Self.openRequiredDirectory(
                    parentDescriptor: installationDescriptor,
                    name: commandName
                )
                defer { close(commandDescriptor) }
                try Self.requireMatchingCommitment(
                    request,
                    commandDescriptor: commandDescriptor
                )
                throw Self.outcomeUnavailable()
            }
            throw Self.ioFailure("failed to claim guest command")
        }
        let commandDescriptor = try Self.openRequiredDirectory(
            parentDescriptor: installationDescriptor,
            name: commandName
        )
        do {
            try Self.writeExclusive(
                Self.commitment(for: request),
                named: Self.commitmentFileName,
                parentDescriptor: commandDescriptor
            )
            guard fsync(commandDescriptor) == 0,
                  fsync(installationDescriptor) == 0,
                  fsync(rootDescriptor) == 0
            else {
                throw Self.ioFailure(
                    "failed to synchronize guest command claim"
                )
            }
        } catch {
            close(commandDescriptor)
            throw error
        }
        return LumeGuestCommandClaim(
            commandDescriptor: commandDescriptor
        )
    }

    static func commitment(
        for request: SandboxGuestCommandRequest
    ) throws -> Data {
        let payload = RequestCommitment(
            schemaVersion: 1,
            executable: request.executable,
            arguments: request.arguments,
            environment: request.environment
                .map { EnvironmentEntry(name: $0.key, value: $0.value) }
                .sorted { $0.name < $1.name },
            workingDirectory: request.workingDirectory,
            timeoutSeconds: request.timeoutSeconds
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded: Data
        do {
            encoded = try encoder.encode(payload)
        } catch {
            throw SandboxRuntimeError.unsupported(
                "guest command commitment cannot be encoded"
            )
        }
        return Data(
            SHA256.hash(data: encoded)
                .map { String(format: "%02x", $0) }
                .joined()
                .utf8
        )
    }

    private static func requireMatchingCommitment(
        _ request: SandboxGuestCommandRequest,
        commandDescriptor: Int32
    ) throws {
        guard let stored = try readFileIfPresent(
            named: commitmentFileName,
            parentDescriptor: commandDescriptor,
            maximumBytes: commitmentByteCount
        ), stored.count == commitmentByteCount else {
            throw outcomeUnavailable()
        }
        guard stored == (try commitment(for: request)) else {
            throw SandboxRuntimeError.unsupported(
                "guest command idempotency key was already used for a different request"
            )
        }
    }

    private static func openPrivateDirectory(_ url: URL) throws -> Int32 {
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

    private static func openOrCreatePrivateDirectory(
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

    private static func openDirectoryIfPresent(
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

    private static func openRequiredDirectory(
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

    private static func requirePrivateDirectory(_ descriptor: Int32) throws {
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

    private static func writeExclusive(
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

    fileprivate static func publishResult(
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
        let cloneStatus = resultFileName.withCString { destination in
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
                   named: resultFileName,
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
            named: resultFileName,
            parentDescriptor: commandDescriptor,
            maximumBytes: LumeGuestCommandEnvelope.maximumEnvelopeBytes
        ), committed == envelope,
              fsync(commandDescriptor) == 0
        else {
            throw ioFailure("guest command result publication is uncertain")
        }
    }

    private static func readFileIfPresent(
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
                    throw ioFailure("guest command journal file changed while reading")
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
            throw ioFailure("guest command journal file changed while reading")
        }
        return data
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

    private static func outcomeUnavailable() -> SandboxRuntimeError {
        .unsupported(
            "guest command outcome is unavailable for an already claimed idempotency key"
        )
    }

    private static func ioFailure(_ detail: String) -> SandboxRuntimeError {
        .unsupported("\(detail) (errno \(errno))")
    }

    private struct RequestCommitment: Encodable {
        let schemaVersion: UInt16
        let executable: String
        let arguments: [String]
        let environment: [EnvironmentEntry]
        let workingDirectory: String
        let timeoutSeconds: UInt32
    }

    private struct EnvironmentEntry: Encodable {
        let name: String
        let value: String
    }
}

final class LumeGuestCommandClaim: @unchecked Sendable {
    private let commandDescriptor: Int32

    fileprivate init(commandDescriptor: Int32) {
        self.commandDescriptor = commandDescriptor
    }

    func complete(envelope: Data) throws {
        try LumeGuestCommandJournal.publishResult(
            envelope,
            commandDescriptor: commandDescriptor
        )
    }

    deinit {
        close(commandDescriptor)
    }
}
