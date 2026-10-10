import Foundation

/// This prefix is public framing, authenticated by AEAD only when open succeeds.
/// No inference payload or unbounded/variable-length field belongs in it.
struct ClusterRecordHeader: Sendable {
    static let byteCount = 24
    static let tagByteCount = 16
    static let magic: [UInt8] = [0x44, 0x42, 0x52, 0x44] // DBRD
    let direction: UInt8
    let type: ClusterRecordType
    let sequence: UInt64
    let plaintextBytes: Int

    var encoded: Data {
        var result = Data(Self.magic)
        result.append(contentsOf: [1, ClusterRecordSuite.aes256GcmHkdfSha256V1.rawValue, direction, type.rawValue])
        result.clusterAppendBigEndian(sequence)
        result.clusterAppendBigEndian(UInt32(plaintextBytes))
        result.append(contentsOf: [0, 0, 0, 0])
        return result
    }

    static func decode(_ prefix: Data, maximumPlaintextBytes: Int) throws -> Self {
        guard (1...ClusterRecordLimits.hardMaximumPlaintextBytes).contains(maximumPlaintextBytes) else {
            throw ClusterRecordError.invalidConfiguration
        }
        guard prefix.count == byteCount else { throw ClusterRecordError.malformedRecord }
        let bytes = Array(prefix) // Exactly 24 bytes; independent of Data slice indices.
        guard Array(bytes[0..<4]) == magic, bytes[4] == 1,
              bytes[5] == ClusterRecordSuite.aes256GcmHkdfSha256V1.rawValue,
              bytes[6] <= 1, let type = ClusterRecordType(rawValue: bytes[7]),
              bytes[20..<24].allSatisfy({ $0 == 0 }) else {
            throw ClusterRecordError.malformedRecord
        }
        var sequence: UInt64 = 0
        for byte in bytes[8..<16] { sequence = (sequence << 8) | UInt64(byte) }
        var length: UInt32 = 0
        for byte in bytes[16..<20] { length = (length << 8) | UInt32(byte) }
        guard length > 0, UInt64(length) <= UInt64(maximumPlaintextBytes) else {
            throw ClusterRecordError.recordTooLarge
        }
        return .init(direction: bytes[6], type: type, sequence: sequence, plaintextBytes: Int(length))
    }

    var recordByteCount: Int { Self.byteCount + plaintextBytes + Self.tagByteCount }

    var nonceBytes: Data {
        // Directional keys are distinct too. Sequence is global to the session,
        // including setup records; it is never reset for a new request.
        var result = Data([0x44, 0x42, 1, direction])
        result.clusterAppendBigEndian(sequence)
        return result
    }
}
