import Darwin
import Foundation
import SandboxCore
import SandboxRuntime

extension LumeVirtualMachineRuntime {
    /// Removes an exact, unqualified Apple restore. The ordinary deletion intent
    /// retains stopped/directory identity across interrupted native removal.
    /// Successful replay proves absence, not a new deletion or qualification.
    package func discardUnqualifiedBase(name: String, installationID: UUID) async throws {
        guard capacityArbiter == nil, let authority = configuration.hostRuntimeLease else {
            throw SandboxRuntimeError.unsupported("base discard requires exclusive base-runtime ownership")
        }
        try authority.validateExclusive()
        try await performDelete(name: name, scope: nil, releaseCapacity: false,
            unqualifiedBaseInstallationID: installationID)
    }
}

enum LumeUnqualifiedBaseDeletion {
    /// Called while holding the same operation lock used by preparation,
    /// qualification and ordinary cloning. Malformed readiness is preserved too.
    static func require(name: String, installationID: UUID, storage: URL) throws {
        let source = try LumeGuestTemplateSource.load(name: name, installationID: installationID, storage: storage)
        guard source.kind == .appleRestore else {
            throw SandboxRuntimeError.unsupported("base discard requires raw Apple restore ownership")
        }
        let directory = try SandboxAuthorityFileSystem.openPrivateDirectory(
            at: storage.appendingPathComponent(name), createIfMissing: false)
        defer { close(directory) }
        for name in [SandboxGuestTemplateReceipt.fileName, ".darkbloom-guest"] {
            var metadata = stat()
            if fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
                throw SandboxRuntimeError.unsupported("base discard refuses a ready template or guest material")
            }
            guard errno == ENOENT else {
                throw SandboxRuntimeError.unsupported("base discard cannot verify absence of prepared artifacts")
            }
        }
    }
}
