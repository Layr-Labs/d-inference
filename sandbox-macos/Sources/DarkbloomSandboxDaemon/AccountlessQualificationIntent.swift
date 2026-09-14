import Foundation
import SandboxCore
import SandboxRuntime

struct AccountlessQualificationIntent: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let permit: AccountlessBootPermit
    let collection: AccountlessCollectionRecord
    let capacityDirectory: String
    let guestReleaseDirectory: String
    let guestReleaseSHA256: String
    let qualificationID: UUID
    let sandboxID: SandboxID
    let expiresAt: Date

    var cloneName: String { "dbqual-" + qualificationID.uuidString.lowercased() }
    var generation: SandboxGeneration { SandboxGeneration(rawValue: 1)! }

    func validate() throws {
        let candidate = try permit.candidate()
        try collection.validate(permit: permit)
        guard schemaVersion == 1, BaseGuestRelease.isDigest(guestReleaseSHA256),
              ![candidate.candidateID, candidate.bootstrapAttemptID, candidate.source.installationID].contains(qualificationID),
              SandboxVirtualMachineNamePolicy.isValid(cloneName), cloneName != candidate.source.name,
              expiresAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970 > 0 else {
            throw AccountlessInstallationError.invalidBinding
        }
        for path in [capacityDirectory, guestReleaseDirectory] {
            guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0"),
                  path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
                    .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw AccountlessInstallationError.invalidBinding }
        }
    }

    func validateLease(_ lease: SandboxCapacityLease) throws {
        let candidate = try permit.candidate(), resources = candidate.resources
        guard lease.scope.sandboxID == sandboxID, lease.scope.generation == generation,
              lease.virtualMachineName == cloneName, lease.cpuCount == resources.cpuCount,
              lease.memoryBytes == resources.memoryBytes, lease.workspaceBytes == resources.workspaceBytes,
              lease.bootDiskBytes == candidate.disk.size, lease.expiresAt == expiresAt,
              lease.reservedGrowthBytes == (try SandboxStorageReservation.growthBytes(
                bootDiskBytes: lease.bootDiskBytes, workspaceBytes: lease.workspaceBytes)) else {
            throw AccountlessInstallationError.invalidBinding
        }
    }
}
