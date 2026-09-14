import Darwin
import Foundation
import SandboxCore
import SandboxRuntime

enum LumeGuestTemplate {
    static func requireReady(name: String, installationID: UUID, storage: URL,
                             release: LumeGuestMaterialConfiguration) throws {
        let files = try release.validatedReleaseFiles()
        let directory = try SandboxAuthorityFileSystem.openPrivateDirectory(
            at: storage.appendingPathComponent(name), createIfMissing: false)
        defer { close(directory) }
        try LumeOfflineOperationFence.requireAbsent(directory: directory, name: name)
        let file = openat(directory, SandboxGuestTemplateReceipt.fileName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard file >= 0 else { throw failure() }
        defer { close(file) }
        let receipt = try JSONDecoder().decode(SandboxGuestTemplateReceipt.self,
            from: SandboxAuthorityFileSystem.readStablePrivateFile(file, maximumBytes: 16 * 1024))
        let source = try LumeGuestTemplateSource.load(name: name, installationID: installationID, storage: storage)
        guard receipt.isReady(for: source, guestFiles: files) else { throw failure() }
        // The installation manifest remains provenance. Compatibility follows
        // exact guest bytes authenticated by the current signed manifest.
        guard try release.validatedReleaseFiles() == files,
              try LumeGuestTemplateSource.load(name: name, installationID: installationID, storage: storage) == source else { throw failure() }
    }

    private static func failure() -> SandboxRuntimeError {
        .unsupported("base image lacks a matching signed-guest installation and stopped-state receipt")
    }
}
