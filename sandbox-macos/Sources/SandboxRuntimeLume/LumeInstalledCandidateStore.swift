import CryptoKit
import Darwin
import Foundation
import SandboxCore
import SandboxRuntime

/// Read-only, descriptor-bound candidate evidence. The caller retains the
/// source operation lock while this reader checks and rechecks its namespace.
final class LumeInstalledCandidateStore: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let checkpoint: LumeInstalledCandidateCheckpoint
        let checkpointSHA256: String
        let installation: SandboxAccountlessInstallationReceipt
    }
    private let storage: URL
    private let name: String
    private let storageFD: Int32
    private let directoryFD: Int32

    init(name: String, storage: URL) throws {
        guard SandboxVirtualMachineNamePolicy.isValid(name) else { throw SandboxRuntimeError.invalidName }
        self.storage = storage; self.name = name
        let parent = try SandboxAuthorityFileSystem.openPrivateDirectory(at: storage, createIfMissing: false)
        do {
            directoryFD = try SandboxAuthorityFileSystem.openPrivateChildDirectory(
                parentDescriptor: parent, name: name, createIfMissing: false)
            storageFD = parent
        } catch { close(parent); throw error }
    }
    deinit { close(directoryFD); close(storageFD) }

    func read(source: SandboxGuestBaseSource, guestFiles: [String: String]) throws -> Snapshot {
        try requireNamespace()
        try requireAbsent(SandboxGuestTemplateReceipt.fileName)
        try requireAbsent(".darkbloom-guest")
        let data = try readFile(LumeInstalledCandidateCheckpoint.fileName)
        let checkpoint = try JSONDecoder().decode(LumeInstalledCandidateCheckpoint.self, from: data)
        guard checkpoint.isValid, checkpoint.source == source,
              checkpoint.payload.matchesGuestFiles(guestFiles), checkpoint.source.name == name else { throw Self.failure() }
        let reservationData = try readFile(LumeInstalledCandidateCheckpoint.reservationFileName)
        let installationData = try readFile(LumeInstalledCandidateCheckpoint.installationFileName)
        let cleanupData = try readFile(LumeInstalledCandidateCheckpoint.cleanupFileName)
        guard Self.digest(reservationData) == checkpoint.reservationSHA256,
              Self.digest(installationData) == checkpoint.installationReceiptSHA256,
              Self.digest(cleanupData) == checkpoint.cleanupReceiptSHA256 else { throw Self.failure() }
        let reservation = try JSONDecoder().decode(LumeReservedCandidateRecord.self, from: reservationData)
        let installation = try JSONDecoder().decode(SandboxAccountlessInstallationReceipt.self, from: installationData)
        let cleanup = try JSONDecoder().decode(LumeCandidateInstallationCleanup.self, from: cleanupData)
        guard reservation.matches(checkpoint), installation.installationComplete,
              installation.rootJobID == checkpoint.bootstrapAttemptID,
              installation.source == source, installation.payload == checkpoint.payload,
              cleanup.matches(checkpoint), try diskIdentity() == checkpoint.disk else { throw Self.failure() }
        try requireNamespace()
        return Snapshot(checkpoint: checkpoint, checkpointSHA256: Self.digest(data), installation: installation)
    }

    func diskIdentity() throws -> LumeCandidateDiskIdentity {
        try requireNamespace()
        let file = openat(directoryFD, "disk.img", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw Self.failure() }
        defer { close(file) }
        let info = try SandboxAuthorityFileSystem.requirePrivateRegularFile(file, allowEmpty: false)
        guard info.st_size > 0 else { throw Self.failure() }
        try requireNamed(file, name: "disk.img")
        return LumeCandidateDiskIdentity(info)
    }

    private func readFile(_ name: String) throws -> Data {
        let file = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw Self.failure() }
        defer { close(file) }
        let data = try SandboxAuthorityFileSystem.readStablePrivateFile(file, maximumBytes: 16 * 1024)
        try requireNamed(file, name: name)
        return data
    }

    private func requireNamed(_ file: Int32, name: String) throws {
        let current = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw Self.failure() }
        defer { close(current) }
        guard try SandboxAuthorityFileSystem.sameIdentity(SandboxAuthorityFileSystem.fileMetadata(file),
            SandboxAuthorityFileSystem.fileMetadata(current)) else { throw Self.failure() }
    }

    private func requireAbsent(_ name: String) throws {
        var info = stat()
        guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw Self.failure() }
    }

    private func requireNamespace() throws {
        let currentStorage = try SandboxAuthorityFileSystem.openPrivateDirectory(at: storage, createIfMissing: false)
        defer { close(currentStorage) }
        let currentDirectory = try SandboxAuthorityFileSystem.openPrivateChildDirectory(
            parentDescriptor: currentStorage, name: name, createIfMissing: false)
        defer { close(currentDirectory) }
        guard try SandboxAuthorityFileSystem.sameIdentity(SandboxAuthorityFileSystem.fileMetadata(storageFD),
            SandboxAuthorityFileSystem.fileMetadata(currentStorage)),
              try SandboxAuthorityFileSystem.sameIdentity(SandboxAuthorityFileSystem.fileMetadata(directoryFD),
            SandboxAuthorityFileSystem.fileMetadata(currentDirectory)) else { throw Self.failure() }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func failure() -> SandboxRuntimeError {
        .unsupported("installed accountless candidate evidence or disk identity does not match")
    }
}
