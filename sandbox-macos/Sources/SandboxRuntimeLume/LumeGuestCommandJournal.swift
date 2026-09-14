import CryptoKit
import Darwin
import Foundation
import SandboxRuntime

enum LumeGuestCommandReplay: Equatable {
    case unclaimed
    case indeterminate
    case completed(SandboxGuestCommandResult)
    case conflictingCompleted(SandboxGuestCommandResult)
}

struct LumeGuestCommandJournal {
    static let commitmentFileName = "request.sha256"
    static let resultFileName = "result.json"
    private static let commitmentByteCount = SHA256.byteCount * 2

    private let workspace: LumeRuntimeWorkspace
    private let ownedVirtualMachineDirectory: URL?

    init(workspace: LumeRuntimeWorkspace, ownedVirtualMachineDirectory: URL? = nil) {
        self.workspace = workspace
        self.ownedVirtualMachineDirectory = ownedVirtualMachineDirectory
    }

    private func prepareRoot() throws -> URL {
        guard let ownedVirtualMachineDirectory else {
            try workspace.prepare()
            return workspace.commandJournalDirectory
        }
        // Never recreate a deleted VM in order to answer an idempotency query.
        let owner = try SandboxAuthorityFileSystem.openPrivateDirectory(at: ownedVirtualMachineDirectory,
            createIfMissing: false)
        defer { close(owner) }
        let journal = try SandboxAuthorityFileSystem.openPrivateChildDirectory(parentDescriptor: owner,
            name: ".darkbloom-command-journal", createIfMissing: true)
        close(journal)
        return ownedVirtualMachineDirectory.appendingPathComponent(".darkbloom-command-journal")
    }

    func replay(
        installationID: UUID,
        request: SandboxGuestCommandRequest
    ) -> LumeGuestCommandReplay {
        let storedReplay: StoredReplay
        do {
            storedReplay = try loadStoredReplay(
                installationID: installationID,
                request: request
            )
        } catch {
            return .indeterminate
        }
        switch storedReplay {
        case .unclaimed:
            return .unclaimed
        case .indeterminate:
            return .indeterminate
        case .completed(let storedCommitment, let result):
            let requestedCommitment: Data
            do {
                requestedCommitment = try Self.commitment(for: request)
            } catch {
                return .indeterminate
            }
            guard storedCommitment == requestedCommitment else {
                return .conflictingCompleted(result)
            }
            return .completed(result)
        }
    }

    private func loadStoredReplay(
        installationID: UUID,
        request: SandboxGuestCommandRequest
    ) throws -> StoredReplay {
        let root = try prepareRoot()
        let rootDescriptor = try LumeGuestCommandJournalIO.openPrivateDirectory(
            root
        )
        defer { close(rootDescriptor) }
        let installationName = installationID.uuidString.lowercased()
        guard let installationDescriptor =
            try LumeGuestCommandJournalIO.openDirectoryIfPresent(
                parentDescriptor: rootDescriptor,
                name: installationName
            )
        else {
            return .unclaimed
        }
        defer { close(installationDescriptor) }
        let commandName = LumeGuestCommandIdentity.identifier(
            for: request.idempotencyKey
        )
        guard let commandDescriptor =
            try LumeGuestCommandJournalIO.openDirectoryIfPresent(
                parentDescriptor: installationDescriptor,
                name: commandName
            )
        else {
            return .unclaimed
        }
        defer { close(commandDescriptor) }

        guard let storedCommitment =
            try LumeGuestCommandJournalIO.readFileIfPresent(
                named: Self.commitmentFileName,
                parentDescriptor: commandDescriptor,
                maximumBytes: Self.commitmentByteCount
            ),
            Self.isCanonicalCommitment(storedCommitment)
        else {
            return .indeterminate
        }
        guard let envelope = try LumeGuestCommandJournalIO.readFileIfPresent(
            named: Self.resultFileName,
            parentDescriptor: commandDescriptor,
            maximumBytes: LumeGuestCommandEnvelope.maximumEnvelopeBytes,
            synchronizeBeforeReturn: true
        ) else {
            return .indeterminate
        }
        return .completed(
            commitment: storedCommitment,
            result: try LumeGuestCommandResultDecoder.decode(envelope)
        )
    }

    func claim(
        installationID: UUID,
        request: SandboxGuestCommandRequest
    ) throws -> LumeGuestCommandClaim {
        let root = try prepareRoot()
        let rootDescriptor = try LumeGuestCommandJournalIO.openPrivateDirectory(
            root
        )
        defer { close(rootDescriptor) }
        let installationDescriptor =
            try LumeGuestCommandJournalIO.openOrCreatePrivateDirectory(
                parentDescriptor: rootDescriptor,
                name: installationID.uuidString.lowercased()
            )
        defer { close(installationDescriptor) }
        let commandName = LumeGuestCommandIdentity.identifier(
            for: request.idempotencyKey
        )
        if let existing = try LumeGuestCommandJournalIO.openDirectoryIfPresent(
            parentDescriptor: installationDescriptor, name: commandName) {
            defer { close(existing) }
            try Self.requireMatchingCommitment(request, commandDescriptor: existing)
            throw Self.outcomeUnavailable()
        }
        try LumeGuestCommandJournalBudget.requireRoom(in: installationDescriptor)
        guard mkdirat(installationDescriptor, commandName, 0o700) == 0 else {
            if errno == EEXIST {
                let commandDescriptor =
                    try LumeGuestCommandJournalIO.openRequiredDirectory(
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
            throw LumeGuestCommandJournalIO.ioFailure(
                "failed to claim guest command"
            )
        }
        let commandDescriptor =
            try LumeGuestCommandJournalIO.openRequiredDirectory(
                parentDescriptor: installationDescriptor,
                name: commandName
            )
        do {
            try LumeGuestCommandJournalIO.writeExclusive(
                Self.commitment(for: request),
                named: Self.commitmentFileName,
                parentDescriptor: commandDescriptor
            )
            try LumeGuestCommandJournalIO.synchronize(
                commandDescriptor,
                subject: "guest command directory"
            )
            try LumeGuestCommandJournalIO.synchronize(
                installationDescriptor,
                subject: "guest command installation directory"
            )
            try LumeGuestCommandJournalIO.synchronize(
                rootDescriptor,
                subject: "guest command journal root"
            )
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

    private static func isCanonicalCommitment(_ data: Data) -> Bool {
        data.count == commitmentByteCount && data.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x61 && byte <= 0x66)
        }
    }

    private static func requireMatchingCommitment(
        _ request: SandboxGuestCommandRequest,
        commandDescriptor: Int32
    ) throws {
        guard let stored = try LumeGuestCommandJournalIO.readFileIfPresent(
            named: commitmentFileName,
            parentDescriptor: commandDescriptor,
            maximumBytes: commitmentByteCount
        ), isCanonicalCommitment(stored) else {
            throw outcomeUnavailable()
        }
        guard stored == (try commitment(for: request)) else {
            throw Self.idempotencyConflict()
        }
    }

    static func idempotencyConflict() -> SandboxRuntimeError {
        .unsupported(
            "guest command idempotency key was already used for a different request"
        )
    }

    static func outcomeUnavailable() -> SandboxRuntimeError {
        .unsupported(
            "guest command outcome is unavailable for an already claimed idempotency key"
        )
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

    private enum StoredReplay {
        case unclaimed
        case indeterminate
        case completed(
            commitment: Data,
            result: SandboxGuestCommandResult
        )
    }
}

final class LumeGuestCommandClaim: @unchecked Sendable {
    private let commandDescriptor: Int32

    fileprivate init(commandDescriptor: Int32) {
        self.commandDescriptor = commandDescriptor
    }

    func complete(envelope: Data) throws {
        try LumeGuestCommandJournalIO.publishResult(
            envelope,
            commandDescriptor: commandDescriptor
        )
    }

    deinit {
        close(commandDescriptor)
    }
}
