import Foundation
import MLXLMCommon

/// Qwen4 byte-level vocabulary projection used only to track ASCII framing.
/// Non-ASCII payload bytes remain opaque; generated token IDs are not rewritten.
final class Qwen4ToolFramingVocabulary: @unchecked Sendable {
    let pieces: [String?]
    let tokenIDs: [Int]
    let nonStopTokenIDs: [Int]
    let stopTokenIDs: Set<Int>

    init(tokenizer: any MLXLMCommon.Tokenizer, stopTokenIDs: Set<Int>) throws {
        guard !stopTokenIDs.isEmpty else {
            throw ToolConstraintSchemaError.invalid("Qwen4 tool envelope requires terminal token IDs")
        }
        // Validate the native Qwen4 framing tokens, not another family's IDs.
        for (text, expected) in [("<tool_call>", 248058), ("</tool_call>", 248059),
                                 ("<think>", 248068), ("</think>", 248069)] {
            guard tokenizer.convertTokenToId(text) == expected,
                  tokenizer.convertIdToToken(expected) == text else {
                throw ToolConstraintSchemaError.invalid("Native Qwen4 framing vocabulary does not match")
            }
        }
        var decoded: [String?] = []
        var missing = 0
        for id in 0..<400_000 {
            guard let raw = tokenizer.convertIdToToken(id) else {
                decoded.append(nil)
                missing += 1
                if !decoded.isEmpty && missing == 1024 {
                    decoded.removeLast(missing)
                    break
                }
                continue
            }
            missing = 0
            decoded.append(Self.framingProjection(raw))
        }
        guard decoded.count > 248069, stopTokenIDs.allSatisfy({ $0 >= 0 && $0 < decoded.count && decoded[$0] != nil }) else {
            throw ToolConstraintSchemaError.invalid("Incomplete native Qwen4 vocabulary")
        }
        self.pieces = decoded
        self.tokenIDs = decoded.indices.filter { decoded[$0] != nil }
        self.stopTokenIDs = stopTokenIDs
        self.nonStopTokenIDs = tokenIDs.filter { !stopTokenIDs.contains($0) }
    }

    /// Injectable tiny vocabulary for deterministic boundary tests.
    init(pieces: [String?], stopTokenIDs: Set<Int>) {
        self.pieces = pieces
        self.tokenIDs = pieces.indices.filter { pieces[$0] != nil }
        self.stopTokenIDs = stopTokenIDs
        self.nonStopTokenIDs = tokenIDs.filter { !stopTokenIDs.contains($0) }
    }

    private static let byteDecoder: [Unicode.Scalar: UInt8] = {
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var scalars = bytes
        var extra = 0
        for byte in 0...255 where !bytes.contains(byte) {
            bytes.append(byte); scalars.append(256 + extra); extra += 1
        }
        return Dictionary(uniqueKeysWithValues: zip(scalars, bytes).map { (Unicode.Scalar($0.0)!, UInt8($0.1)) })
    }()

    static func framingProjection(_ raw: String) -> String {
        String(String.UnicodeScalarView(raw.unicodeScalars.map { scalar in
            guard let byte = byteDecoder[scalar], byte < 128 else { return Unicode.Scalar(0xFFFD)! }
            return Unicode.Scalar(Int(byte))!
        }))
    }
}
