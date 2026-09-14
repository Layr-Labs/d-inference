import Darwin
import Foundation
import SandboxCore
import SandboxRuntime
import SandboxRuntimeLume

/// An exclusive, descriptor-bound snapshot. Failure retains the VM and any
/// record already published; this store never repairs or starts an installer.
final class AccountlessBaseCandidateStore {
    let directory: URL
    private let descriptor: Int32

    init(directory: URL) throws {
        self.directory = directory
        descriptor = try SandboxAuthorityFileSystem.openPrivateDirectory(at: directory, createIfMissing: false)
    }
    deinit { close(descriptor) }

    var recordPath: String { directory.appendingPathComponent(AccountlessBaseCandidateRecord.fileName).path }

    func requireNoPreparedArtifacts() throws {
        try requireBoundDirectory()
        for name in [SandboxGuestTemplateReceipt.fileName, ".darkbloom-guest", LumeInstalledCandidateCheckpoint.bootClaimFileName] {
            var metadata = stat()
            if fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
                throw AccountlessBaseCandidateError.preparedArtifactsPresent
            }
            guard errno == ENOENT else { throw AccountlessBaseCandidateError.unsafeImage }
        }
    }

    func read() throws -> AccountlessBaseCandidateRecord? {
        try requireBoundDirectory()
        let file = openat(descriptor, AccountlessBaseCandidateRecord.fileName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if file < 0 && errno == ENOENT { return nil }
        guard file >= 0 else { throw AccountlessBaseCandidateError.invalidRecord }
        defer { close(file) }
        let data = try SandboxAuthorityFileSystem.readStablePrivateFile(file, maximumBytes: 16 * 1024)
        let record = try JSONDecoder().decode(AccountlessBaseCandidateRecord.self, from: data)
        guard record.isValid else { throw AccountlessBaseCandidateError.invalidRecord }
        return record
    }

    func diskIdentity(expectedBytes: UInt64) throws -> AccountlessBaseDiskIdentity {
        try requireBoundDirectory()
        let file = openat(descriptor, "disk.img", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard file >= 0 else { throw AccountlessBaseCandidateError.unsafeImage }
        defer { close(file) }
        let info = try SandboxAuthorityFileSystem.requirePrivateRegularFile(file, allowEmpty: false)
        guard info.st_size > 0, UInt64(info.st_size) == expectedBytes else { throw AccountlessBaseCandidateError.unsafeImage }
        let named = openat(descriptor, "disk.img", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard named >= 0 else { throw AccountlessBaseCandidateError.unsafeImage }
        defer { close(named) }
        let rebound = try SandboxAuthorityFileSystem.requirePrivateRegularFile(named, allowEmpty: false)
        guard SandboxAuthorityFileSystem.sameIdentity(info, rebound), snapshot(info) == snapshot(rebound) else {
            throw AccountlessBaseCandidateError.candidateChanged
        }
        return snapshot(info)
    }

    func publish(_ record: AccountlessBaseCandidateRecord) throws {
        try requireBoundDirectory()
        guard record.isValid else { throw AccountlessBaseCandidateError.invalidRecord }
        let file = try SandboxAuthorityFileSystem.createUnlinkedPrivateFile(parentDescriptor: descriptor, prefix: "base-candidate")
        defer { close(file) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        guard data.count <= 16 * 1024 else { throw AccountlessBaseCandidateError.invalidRecord }
        try SandboxAuthorityFileSystem.writeAll(data, to: file)
        try SandboxAuthorityFileSystem.synchronize(file)
        guard fclonefileat(file, descriptor, AccountlessBaseCandidateRecord.fileName, 0) == 0 else {
            throw AccountlessBaseCandidateError.invalidRecord
        }
        try SandboxAuthorityFileSystem.synchronize(descriptor)
        guard try read() == record else { throw AccountlessBaseCandidateError.candidateChanged }
    }

    private func snapshot(_ info: stat) -> AccountlessBaseDiskIdentity {
        .init(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino), size: UInt64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }

    private func requireBoundDirectory() throws {
        let named = try SandboxAuthorityFileSystem.openPrivateDirectory(at: directory, createIfMissing: false)
        defer { close(named) }
        guard try SandboxAuthorityFileSystem.sameIdentity(SandboxAuthorityFileSystem.fileMetadata(descriptor),
            SandboxAuthorityFileSystem.fileMetadata(named)) else { throw AccountlessBaseCandidateError.candidateChanged }
    }
}
