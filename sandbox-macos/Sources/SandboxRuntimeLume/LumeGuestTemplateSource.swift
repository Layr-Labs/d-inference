import CryptoKit
import Darwin
import Foundation
import SandboxCore
import SandboxRuntime

/// A descriptor-read commitment to an already-owned base. This grants no clone
/// or readiness capability and never adopts an arbitrary VM directory.
package enum LumeGuestTemplateSource {
    package static func load(name: String, installationID: UUID, storage: URL) throws -> SandboxGuestBaseSource {
        let identity = try LumeVirtualMachineOwnership.requireOwned(name: name, owner: .baseTemplate, in: storage)
        guard identity.installationID == installationID else { throw failure() }
        let directory = try SandboxAuthorityFileSystem.openPrivateDirectory(
            at: storage.appendingPathComponent(name), createIfMissing: false)
        defer { close(directory) }
        let descriptor = openat(directory, LumeVirtualMachineOwnership.fileName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw failure() }
        defer { close(descriptor) }
        let data = try SandboxAuthorityFileSystem.readStablePrivateFile(descriptor, maximumBytes: 16 * 1024)
        let record = try JSONDecoder().decode(SourceRecord.self, from: data)
        guard record.schemaVersion == 2, record.ownerKind == "base_template", record.name == name,
              record.installationID == installationID, record.sandboxID == nil, record.sandboxGeneration == nil else { throw failure() }
        let source = SandboxGuestBaseSource(name: name, installationID: installationID, kind: record.sourceKind,
            reference: record.sourceReference, ownershipSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        guard source.isValid else { throw failure() }
        return source
    }

    private struct SourceRecord: Decodable {
        let schemaVersion: Int
        let ownerKind: String
        let name: String
        let installationID: UUID
        let sourceKind: SandboxGuestBaseSourceKind
        let sourceReference: String
        let sandboxID: SandboxID?
        let sandboxGeneration: SandboxGeneration?
    }
    private static func failure() -> SandboxRuntimeError { .unsupported("base source ownership commitment is invalid") }
}
