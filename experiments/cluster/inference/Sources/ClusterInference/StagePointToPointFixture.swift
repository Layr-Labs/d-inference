import Foundation
import MLX

/// Exact finite IEEE bit patterns, including both signs of zero. Values are
/// generated as bytes rather than converted by a model or quantization kernel.
enum StagePointToPointFixture {
    static let nativeDTypes: [DType] = [.float32, .float16, .bfloat16]
    static let hiddenSizes = [128, 4096, 8192]
    static let controlDTypes: [DType] = [.uint8, .uint32, .int32, .float16, .bfloat16, .float32]

    static func bytes(dtype: DType, count: Int, shift: Int = 0) throws -> Data {
        let bits: [UInt32]
        switch dtype {
        case .uint8: bits = [0, 255, 1, 128, 127, 42, 3, 17]
        case .uint32: bits = [0, UInt32.max, 1, 0x80000000, 0x7fffffff, 42, 3, 17]
        case .int32: bits = [0, UInt32.max, 1, 0x80000000, 0x7fffffff, 42, 3, 17]
        case .float32: bits = [0, 0x80000000, 0x3f800000, 0xbf800000, 0x3f000000, 0x40000000, 0x00800000, 0x3e800000]
        case .float16: bits = [0, 0x8000, 0x3c00, 0xbc00, 0x3800, 0x4000, 0x0400, 0x3400]
        case .bfloat16: bits = [0, 0x8000, 0x3f80, 0xbf80, 0x3f00, 0x4000, 0x0080, 0x3e80]
        default: throw ProbeError("Unsupported point-to-point fixture dtype")
        }
        guard count > 0, count <= 32 * 8192, (0..<132).contains(shift) else {
            throw ProbeError("Point-to-point fixture exceeds its bound")
        }
        var result = Data(capacity: count * dtype.size)
        for index in 0..<count {
            let word = bits[(index + shift) % bits.count]
            for byte in 0..<dtype.size { result.append(UInt8(truncatingIfNeeded: word >> (8 * byte))) }
        }
        return result
    }

    static func request(epoch: String) throws -> QwenLayerStageRequestSpec {
        var text = epoch
        for offset in [20, 16, 12, 8] { text.insert("-", at: text.index(text.startIndex, offsetBy: offset)) }
        guard let uuid = UUID(uuidString: text) else { throw ProbeError("Invalid point-to-point epoch UUID") }
        return try .init(requestID: uuid, promptCount: 65, chunkSize: 32, outputCount: 4)
    }

    static func identity(caseID: String) throws -> QwenLayerStageWireSourceIdentity {
        func hash(_ field: String) -> String { sha256(Data("stage-p2p-synthetic-v1|\(caseID)|\(field)".utf8)) }
        return try .init(sourceConfigurationSHA256: hash("configuration"),
            artifactAggregateSHA256: hash("artifact"), storageCommitmentSHA256: hash("storage"),
            planFingerprint: hash("plan"), producerStageFingerprint: hash("stage-zero"))
    }

    static func tokens(frame: QwenLayerStageFrame) -> [Int] {
        (frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)).map { 3 + (($0 * 17 + 7) % 509) }
    }

    static func fingerprint() throws -> String {
        struct Identity: Encodable {
            let version = "stage-p2p-synthetic-v1"
            let hiddenSizes: [Int]
            let prompt = 65, chunk = 32, outputs = 4
            let patterns: [String: String]
            let noncontiguousOrder = [0, 2, 4, 1, 3, 5]
        }
        var patterns: [String: String] = [:]
        for dtype in controlDTypes { patterns[String(describing: dtype)] = sha256(try bytes(dtype: dtype, count: 8)) }
        return sha256(try canonicalJSONData(Identity(hiddenSizes: hiddenSizes, patterns: patterns)))
    }
}
