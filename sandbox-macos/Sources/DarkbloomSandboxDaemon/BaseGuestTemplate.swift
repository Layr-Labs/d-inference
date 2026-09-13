import Darwin
import Foundation
import SandboxRuntime
import SandboxCore

extension SandboxGuestTemplateReceipt {
    init(name: String, installationID: UUID, release: BaseGuestRelease, receipt: BaseGuestInstallationReceipt) throws {
        try receipt.validate(release: release)
        self.init(schemaVersion: 1, name: name, installationID: installationID,
            releaseManifestSHA256: release.manifestSHA256, guestSHA256: receipt.guestSHA256,
            bootstrapSHA256: receipt.bootstrapSHA256, launchdSHA256: receipt.launchdSHA256,
            installerSHA256: receipt.installerSHA256,
            guestOperatingSystemVersion: receipt.guestOperatingSystemVersion,
            guestArchitecture: receipt.guestArchitecture, bootstrapRetired: true, stoppedVerified: true)
    }
}

struct BaseGuestTemplateStore {
    static let filename = SandboxGuestTemplateReceipt.fileName
    let directory: URL

    func installationID(name: String) throws -> UUID {
        let folder = try SandboxAuthorityFileSystem.openPrivateDirectory(at: directory, createIfMissing: false)
        defer { close(folder) }
        let descriptor = openat(folder, ".darkbloom-ownership.json", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw BaseGuestPreparationError.unsafeTemplate }
        defer { close(descriptor) }
        let data = try SandboxAuthorityFileSystem.readStablePrivateFile(descriptor, maximumBytes: 16384)
        let record = try JSONDecoder().decode(Ownership.self, from: data)
        guard record.schemaVersion == 2, record.ownerKind == "base_template",
              record.name == name, record.sandboxID == nil, record.sandboxGeneration == nil else {
            throw BaseGuestPreparationError.unsafeTemplate
        }
        return record.installationID
    }

    func matching(name: String, release: BaseGuestRelease) throws -> SandboxGuestTemplateReceipt? {
        let folder = try SandboxAuthorityFileSystem.openPrivateDirectory(at: directory, createIfMissing: false)
        defer { close(folder) }
        let descriptor = openat(folder, Self.filename, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0 && errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw BaseGuestPreparationError.unsafeTemplate }
        defer { close(descriptor) }
        let data = try SandboxAuthorityFileSystem.readStablePrivateFile(descriptor, maximumBytes: 16384)
        let record = try JSONDecoder().decode(SandboxGuestTemplateReceipt.self, from: data)
        guard record.schemaVersion == 1, record.name == name,
              record.installationID == (try installationID(name: name)),
              BaseGuestRelease.isDigest(record.releaseManifestSHA256),
              record.guestSHA256 == release.hashes["darkbloom-sandbox-guest"],
              record.bootstrapSHA256 == release.hashes["darkbloom-sandbox-bootstrap.sh"],
              record.launchdSHA256 == release.hashes["io.darkbloom.sandbox.guest.plist"],
              record.installerSHA256 == release.hashes["install-sandbox-guest.sh"],
              record.guestArchitecture == "arm64", record.bootstrapRetired, record.stoppedVerified else {
            throw BaseGuestPreparationError.staleTemplate
        }
        return record
    }

    func publish(_ record: SandboxGuestTemplateReceipt) throws {
        guard try installationID(name: record.name) == record.installationID else {
            throw BaseGuestPreparationError.staleTemplate
        }
        let folder = try SandboxAuthorityFileSystem.openPrivateDirectory(at: directory, createIfMissing: false)
        defer { close(folder) }
        let descriptor = try SandboxAuthorityFileSystem.createUnlinkedPrivateFile(parentDescriptor: folder, prefix: "template")
        defer { close(descriptor) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try SandboxAuthorityFileSystem.writeAll(encoder.encode(record), to: descriptor)
        try SandboxAuthorityFileSystem.synchronize(descriptor)
        guard fclonefileat(descriptor, folder, Self.filename, 0) == 0 else {
            throw BaseGuestPreparationError.unsafeTemplate
        }
        try SandboxAuthorityFileSystem.synchronize(folder)
    }

    private struct Ownership: Decodable {
        let schemaVersion: Int
        let installationID: UUID
        let ownerKind: String
        let name: String
        let sandboxID: String?
        let sandboxGeneration: UInt64?
    }
}
