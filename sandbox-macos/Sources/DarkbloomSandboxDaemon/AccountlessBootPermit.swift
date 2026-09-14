import Foundation
import SandboxRuntime
import SandboxRuntimeLume

/// Public-to-the-selected-host, root-owned immutable permission for one boot.
/// Contains no credential and makes no installation or qualification claim.
struct AccountlessBootPermit: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let hostID: UUID
    let hostUser: HostUserIdentity
    let hostIdentityFile: String
    let storage: String
    let runtime: String
    let runtimeSHA256: String
    let reservationData: Data
    let stagedDisk: LumeCandidateDiskIdentity
    let stagingSnapshotSHA256: String
    let maximumBootSeconds: UInt32

    func candidate() throws -> AccountlessBaseCandidateRecord {
        let candidate = try AccountlessJournalJSON.decode(AccountlessBaseCandidateRecord.self, reservationData)
        try hostUser.validate()
        guard schemaVersion == 1, maximumBootSeconds == 300, candidate.isValid,
              [hostIdentityFile, storage, runtime].allSatisfy(Self.isPath),
              [runtimeSHA256, stagingSnapshotSHA256].allSatisfy(BaseGuestRelease.isDigest),
              stagedDisk.device == candidate.disk.device, stagedDisk.inode == candidate.disk.inode,
              stagedDisk.size == candidate.disk.size, stagedDisk.inode > 0,
              (0..<1_000_000_000).contains(stagedDisk.modifiedNanoseconds),
              (0..<1_000_000_000).contains(stagedDisk.changedNanoseconds) else { throw AccountlessInstallationError.invalidBinding }
        _ = try SandboxVirtualMachineSpecification(name: candidate.source.name, resources: candidate.resources,
            imageSource: .appleRestore(url: URL(fileURLWithPath: candidate.source.reference)), diskBytes: stagedDisk.size)
        return candidate
    }

    func encoded() throws -> Data {
        _ = try candidate()
        let data = try AccountlessJournalJSON.encode(self)
        guard data.count <= HostUserIdentityFile.maximumBytes else { throw AccountlessInstallationError.invalidBinding }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        let value = try AccountlessJournalJSON.decode(Self.self, data)
        guard data == (try value.encoded()) else { throw AccountlessInstallationError.invalidBinding }
        return value
    }

    func request() throws -> LumeInstallerBootRequest {
        .init(reservationData: reservationData, stagedDisk: stagedDisk, runtimeSHA256: runtimeSHA256,
            maximumBootSeconds: maximumBootSeconds, permitSHA256: BaseGuestRelease.digest(try encoded()))
    }

    private static func isPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && path.utf8.count <= 4096
            && !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
            && path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    }
}
