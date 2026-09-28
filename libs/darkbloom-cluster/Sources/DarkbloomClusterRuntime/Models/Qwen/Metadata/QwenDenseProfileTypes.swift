import Foundation
import CryptoKit

struct QwenDenseProfileError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

enum QwenDenseProfileIdentity {
    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func fingerprint(_ fields: [String]) -> String {
        sha256(Data(fields.joined(separator: "\n").utf8))
    }
    static func encodedFingerprint<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return sha256(try encoder.encode(value))
    }
}

enum QwenRegisteredDenseModel: String, Codable, CaseIterable {
    case qwen35NineB = "registered_qwen35_9b"
    case qwen38TwentySevenB = "registered_qwen38_27b"
}

/// Caller-supplied metadata, not a trusted descriptor or load permission. The
/// closed profile validates every entry and the exact complete inventory hash.
struct QwenDenseCanonicalTensor: Codable, Equatable {
    let name: String
    let shape: [Int]
    let sourceDType: String
    let byteCount: Int

    func validate() throws {
        guard (1...512).contains(name.utf8.count), name.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 95
        }), (1...4).contains(shape.count), shape.allSatisfy({ $0 > 0 && $0 <= Int(Int32.max) }) else {
            throw QwenDenseProfileError("Canonical tensor has an invalid name or bounded shape")
        }
        let width: Int
        switch sourceDType {
        case "U32", "F32": width = 4
        case "F16", "BF16": width = 2
        default: throw QwenDenseProfileError("Canonical tensor has an unsupported source dtype")
        }
        guard byteCount > 0, byteCount == (try QwenLongPrefillCheckedBytes.product(shape + [width])) else {
            throw QwenDenseProfileError("Canonical tensor shape and byte count disagree")
        }
    }
    var identity: String {
        name + "|" + sourceDType + "|" + shape.map(String.init).joined(separator: ",") + "|" + String(byteCount)
    }
}

/// These identify prospective accounting scopes, never execution eligibility.
enum QwenDenseStorageRole: String, Codable, CaseIterable {
    case fullReference, fullSolo, sequentialPair, stage0, stage1
    var stageIndex: Int? {
        switch self { case .stage0: return 0; case .stage1: return 1; default: return nil }
    }
}

struct QwenDenseFinalStateGeometry: Encodable, Equatable {
    let committedTokens: Int
    let attentionLayers: Int, recurrentLayers: Int, componentCount: Int
    let kvShape: [Int], convolutionShape: [Int], ssmShape: [Int]
    let kvDType = "bfloat16", convolutionDType = "bfloat16", ssmDType = "float32", offsetDType = "int32"
    let kvBytesPerTensor: Int, convolutionBytesPerTensor: Int, ssmBytesPerTensor: Int
    let logicalBytes: Int
}
