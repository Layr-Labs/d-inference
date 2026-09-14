import Darwin
import Foundation
import HostRuntimeCoordination
import SandboxCore

/// One image's immutable link to the machine-wide root maintenance intent.
/// This records authority/binding only; it contains no cleanup or readiness claim.
struct LumeImageMaintenanceRecord: Codable, Equatable {
    let schemaVersion: UInt16
    let maintenance: HostRuntimeMaintenanceIntent
    let source: SandboxGuestBaseSource
    let reservationSHA256: String
    let directoryDevice: UInt64
    let directoryInode: UInt64
    let disk: LumeCandidateDiskIdentity

    init(source: LumeBaseImageSourceLocks, maintenance: HostRuntimeMaintenanceIntent) throws {
        var info = stat()
        guard fstat(source.directoryDescriptor, &info) == 0 else { throw POSIXError(.EIO) }
        schemaVersion = 1; self.maintenance = maintenance
        self.source = source.baseSource; reservationSHA256 = source.reservationSHA256
        directoryDevice = UInt64(UInt32(bitPattern: info.st_dev)); directoryInode = UInt64(info.st_ino)
        disk = source.initialDisk
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
