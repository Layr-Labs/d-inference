import Foundation
import SandboxCore
import SandboxRuntime

/// The daemon constructs this only after reading the protected root boot permit.
/// Source validation and a durable claim are still mandatory before native spawn.
package struct LumeInstallerBootRequest: Codable, Equatable, Sendable {
    package let reservationData: Data
    package let stagedDisk: LumeCandidateDiskIdentity
    package let runtimeSHA256: String
    package let maximumBootSeconds: UInt32
    package let permitSHA256: String

    package init(reservationData: Data, stagedDisk: LumeCandidateDiskIdentity, runtimeSHA256: String,
                 maximumBootSeconds: UInt32, permitSHA256: String) {
        self.reservationData = reservationData; self.stagedDisk = stagedDisk; self.runtimeSHA256 = runtimeSHA256
        self.maximumBootSeconds = maximumBootSeconds; self.permitSHA256 = permitSHA256
    }

    func validate() throws -> LumeReservedCandidateRecord {
        guard reservationData.count <= 16 * 1024, maximumBootSeconds == 300,
              [runtimeSHA256, permitSHA256].allSatisfy(LumeInstalledCandidateCheckpoint.isDigest), stagedDisk.isValid else {
            throw SandboxRuntimeError.unsupported("invalid accountless installer permit")
        }
        try SandboxJSONIntegrity.requireNoDuplicateKeys(reservationData)
        let record = try JSONDecoder().decode(LumeReservedCandidateRecord.self, from: reservationData)
        guard record.schemaVersion == 1, record.phase == "awaitingRootInstallation", !record.installed, !record.qualified,
              record.source.isValid, record.source.kind == .appleRestore, record.payload.isValid,
              record.candidateID != record.bootstrapAttemptID, record.candidateID != record.source.installationID,
              record.bootstrapAttemptID != record.source.installationID, record.disk.isValid,
              record.disk.device == stagedDisk.device, record.disk.inode == stagedDisk.inode,
              record.disk.size == stagedDisk.size else { throw SandboxRuntimeError.unsupported("installer reservation does not match staged image") }
        _ = try SandboxVirtualMachineSpecification(name: record.source.name, resources: record.resources,
            imageSource: .appleRestore(url: URL(fileURLWithPath: record.source.reference)), diskBytes: stagedDisk.size)
        return record
    }
}

package struct LumeInstallerBootOutcome: Sendable {
    package let replayed: Bool
    package let observedRunning: Bool
    package let nativeExitCode: Int32?
    package let sourceStopped: Bool
}
