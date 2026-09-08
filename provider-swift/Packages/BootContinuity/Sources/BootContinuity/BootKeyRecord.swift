import Foundation

/// Internal storage representation. Never expose the handle over a CLI or protocol.
struct BootKeyRecord: Codable {
    static let currentVersion = 1
    static let maximumSize = 32 * 1024

    let version: Int
    let context: BootContinuityContext
    let publicKey: Data
    let opaqueHandle: Data

    init(context: BootContinuityContext, key: any BootHardwareKey) {
        version = Self.currentVersion
        self.context = context
        publicKey = key.publicKey
        opaqueHandle = key.opaqueHandle
    }

    static func decode(_ data: Data, expecting context: BootContinuityContext) throws -> Self {
        guard data.count <= maximumSize else { throw BootContinuityError.invalidRecord }
        let record: Self
        do { record = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw BootContinuityError.invalidRecord }
        guard record.version == currentVersion else { throw BootContinuityError.unsupportedRecordVersion }
        try record.context.validate()
        guard record.context == context else { throw BootContinuityError.contextMismatch }
        guard record.publicKey.count == 64, !record.opaqueHandle.isEmpty,
              record.opaqueHandle.count <= 16 * 1024 else { throw BootContinuityError.invalidRecord }
        return record
    }

    func encode() throws -> Data {
        let encoded = try JSONEncoder().encode(self)
        guard encoded.count <= Self.maximumSize else { throw BootContinuityError.invalidRecord }
        return encoded
    }
}
