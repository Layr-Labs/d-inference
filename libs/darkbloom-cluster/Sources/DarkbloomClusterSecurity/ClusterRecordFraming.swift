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
    /// The direction's key generation (S16 rekey). Zero for a channel without
    /// a rekey policy, which keeps those bytes exactly as before; nonzero only
    /// after the sender moved to a later key. Authenticated with the header.
    let generation: UInt32

    init(direction: UInt8, type: ClusterRecordType, sequence: UInt64, plaintextBytes: Int, generation: UInt32 = 0) {
        self.direction = direction; self.type = type; self.sequence = sequence
        self.plaintextBytes = plaintextBytes; self.generation = generation
    }

    var encoded: Data {
        var result = Data(Self.magic)
        result.append(contentsOf: [1, ClusterRecordSuite.aes256GcmHkdfSha256V1.rawValue, direction, type.rawValue])
        result.clusterAppendBigEndian(sequence)
        result.clusterAppendBigEndian(UInt32(plaintextBytes))
        result.clusterAppendBigEndian(generation)
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
              bytes[6] <= 1, let type = ClusterRecordType(rawValue: bytes[7]) else {
            throw ClusterRecordError.malformedRecord
        }
        var sequence: UInt64 = 0
        for byte in bytes[8..<16] { sequence = (sequence << 8) | UInt64(byte) }
        var length: UInt32 = 0
        for byte in bytes[16..<20] { length = (length << 8) | UInt32(byte) }
        guard length > 0, UInt64(length) <= UInt64(maximumPlaintextBytes) else {
            throw ClusterRecordError.recordTooLarge
        }
        // Whether this generation is acceptable is the channel state's decision
        // (a channel without a rekey policy accepts only zero).
        var generation: UInt32 = 0
        for byte in bytes[20..<24] { generation = (generation << 8) | UInt32(byte) }
        return .init(direction: bytes[6], type: type, sequence: sequence, plaintextBytes: Int(length),
                     generation: generation)
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
