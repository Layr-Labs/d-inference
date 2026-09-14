import CryptoKit
import Foundation
import SandboxCore
import SandboxRuntime

extension LumeVirtualMachineOwnership {
    /// Decode the same ownership schema for privileged offline inspection.
    /// The caller separately verifies the descriptor's owner, mode and binding.
    /// This method grants neither filesystem access nor readiness.
    static func inspectRawBaseMarker(_ data: Data, name: String) throws -> (SandboxGuestBaseSource, ResourceCommitment) {
        guard data.count <= 16 * 1_024 else { throw SandboxRuntimeError.unsupported("raw base ownership marker exceeds size limit") }
        try SandboxJSONIntegrity.requireNoDuplicateKeys(data)
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.isValid, record.matches(owner: .baseTemplate), record.name == name,
              record.sourceKind == "apple_restore" else {
            throw SandboxRuntimeError.unsupported("privileged base inspection requires raw Apple ownership")
        }
        let source = SandboxGuestBaseSource(name: record.name, installationID: record.installationID,
            kind: .appleRestore, reference: record.sourceReference,
            ownershipSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        guard source.isValid else { throw SandboxRuntimeError.unsupported("invalid raw base source") }
        return (source, ResourceCommitment(identity: .init(installationID: record.installationID),
            name: name, cpuCount: record.cpuCount, memoryBytes: record.memoryBytes, diskBytes: record.diskBytes))
    }

}
