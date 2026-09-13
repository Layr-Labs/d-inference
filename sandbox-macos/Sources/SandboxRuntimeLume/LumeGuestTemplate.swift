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
        let file = openat(directory, SandboxGuestTemplateReceipt.fileName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard file >= 0 else { throw failure() }
        defer { close(file) }
        let receipt = try JSONDecoder().decode(SandboxGuestTemplateReceipt.self,
            from: SandboxAuthorityFileSystem.readStablePrivateFile(file, maximumBytes: 16 * 1024))
        guard receipt.schemaVersion == 1, receipt.name == name,
              receipt.installationID == installationID,
              receipt.bootstrapRetired, receipt.stoppedVerified,
              receipt.guestArchitecture == "arm64",
              isDigest(receipt.releaseManifestSHA256),
              [receipt.guestSHA256, receipt.bootstrapSHA256, receipt.launchdSHA256, receipt.installerSHA256].allSatisfy(isDigest),
              receipt.guestSHA256 == files["guest/darkbloom-sandbox-guest"],
              receipt.bootstrapSHA256 == files["guest/darkbloom-sandbox-bootstrap.sh"],
              receipt.launchdSHA256 == files["guest/io.darkbloom.sandbox.guest.plist"],
              receipt.installerSHA256 == files["guest/install-sandbox-guest.sh"] else { throw failure() }
        // The installation manifest remains provenance. Compatibility follows
        // exact guest bytes authenticated by the current signed manifest.
        guard try release.validatedReleaseFiles() == files else { throw failure() }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func failure() -> SandboxRuntimeError {
        .unsupported("base image lacks a matching signed-guest installation and stopped-state receipt")
    }
}
