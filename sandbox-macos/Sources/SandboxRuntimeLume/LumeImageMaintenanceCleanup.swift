import CryptoKit
import Foundation

/// Persist in the protected operator journal before releasing either fence.
/// This is a snapshot bound to one operation, not an independent observation
/// of detach or stopped state. The root operator must observe those first.
package struct LumeImageMaintenanceCleanup: Codable, Equatable {
    package let schemaVersion: UInt16
    package let imageFenceSHA256: String
    package let disk: LumeCandidateDiskIdentity

    init(record: Data, disk: LumeCandidateDiskIdentity) {
        schemaVersion = 1; imageFenceSHA256 = Self.digest(record); self.disk = disk
    }

    func requireMatching(record: Data, disk: LumeCandidateDiskIdentity) throws {
        guard schemaVersion == 1, imageFenceSHA256 == Self.digest(record), self.disk == disk, disk.isValid else {
            throw LumeImageMaintenanceError.changed
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum LumeImageMaintenanceError: Error { case changed, completionStarted }
