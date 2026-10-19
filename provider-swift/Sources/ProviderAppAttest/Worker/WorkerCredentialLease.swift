import CryptoKit
import Darwin
import Foundation
import ProviderBuildEnvironment

/// Serializes the existing Keychain read-modify-write budget across helpers.
/// The lock contains no credentials and is released by the kernel on death.
final class WorkerCredentialLease {
    private let descriptor: WorkerDescriptor
    init(scope: String) throws {
        let directory = BuildEnvironment.current.installDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        let path = directory.appendingPathComponent("app-attest-worker-\(digest).lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AppAttestWorkerError.credentialWriterBusy }
        descriptor = WorkerDescriptor(fd)
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == geteuid(),
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o077 == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AppAttestWorkerError.credentialWriterBusy }
    }
}
