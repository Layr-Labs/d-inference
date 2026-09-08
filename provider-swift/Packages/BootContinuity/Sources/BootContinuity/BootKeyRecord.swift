import CryptoKit
import Foundation

/// Internal representation from authenticated custody and caller-owned context.
/// Never import external records or expose handles over a CLI or protocol.
struct BootKeyRecord: Codable {
    static let currentVersion = 2
    static let maximumSize = 32 * 1024

    let version: Int
    let context: BootContinuityContext
    let publicKey: Data
    let opaqueHandle: Data
    let bindingSignatureDER: Data

    init(context: BootContinuityContext, key: any BootHardwareKey) throws {
        version = Self.currentVersion
        self.context = context
        publicKey = key.publicKey
        opaqueHandle = key.opaqueHandle
        bindingSignatureDER = try key.sign(Self.binding(context: context, publicKey: key.publicKey, handle: key.opaqueHandle))
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
        guard let key = try? P256.Signing.PublicKey(rawRepresentation: record.publicKey),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: record.bindingSignatureDER),
              key.isValidSignature(signature, for: binding(context: record.context, publicKey: record.publicKey, handle: record.opaqueHandle)) else {
            throw BootContinuityError.invalidRecord
        }
        return record
    }

    // Local integrity only. Someone who already possesses the usable handle can
    // make another binding; this is neither hardware policy nor server approval.
    private static func binding(context: BootContinuityContext, publicKey: Data, handle: Data) -> Data {
        var result = Data("darkbloom/boot-record/v2\0".utf8)
        result.append(BootContinuationTranscript.contextFields(context))
        result.append(publicKey)
        result.append(contentsOf: SHA256.hash(data: handle))
        return result
    }

    func encode() throws -> Data {
        let encoded = try JSONEncoder().encode(self)
        guard encoded.count <= Self.maximumSize else { throw BootContinuityError.invalidRecord }
        return encoded
    }
}
