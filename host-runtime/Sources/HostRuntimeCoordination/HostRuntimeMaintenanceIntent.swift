import Foundation

/// Binds the machine fence to a separately protected operator journal. It
/// contains no paths, credentials, guest bytes or unverified cleanup claims.
public struct HostRuntimeMaintenanceIntent: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let operationID: UUID
    public let journalSHA256: String

    public init(operationID: UUID, journalSHA256: String) throws {
        schemaVersion = 1; self.operationID = operationID; self.journalSHA256 = journalSHA256
        try validate()
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    private func validate() throws {
        guard schemaVersion == 1, operationID.uuidString != "00000000-0000-0000-0000-000000000000",
              journalSHA256.utf8.count == 64,
              journalSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw HostRuntimeOwnershipError.invalidMaintenanceIntent
        }
    }
}
