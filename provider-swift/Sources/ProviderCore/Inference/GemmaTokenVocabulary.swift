// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

final class GemmaTokenVocabulary: @unchecked Sendable {
    static let maximumVocabularySize = 400_000
    static let terminalMissingRun = 1_024

    let pieces: [[UInt8]?]
    let byFirstByte: [[Int]]
    let stringSafeTokenIDs: [Int]
    let nonStringSafeTokenIDs: [Int]
    let tokensWithoutLessThan: [Int]
    let tokensWithLessThan: [Int]
    let stopTokenIDs: Set<Int>
    let fallbackTokenID: Int

    init(
        tokenizer: any MLXLMCommon.Tokenizer,
        stopTokenIDs: Set<Int>
    ) throws {
        guard let fallback = stopTokenIDs.min() else {
            throw ToolConstraintSchemaError.invalid(
                "constrained decoding requires at least one stop token")
        }
        var pieces: [[UInt8]?] = []
        pieces.reserveCapacity(262_144)
        var missingRun = 0
        var sawToken = false
        for id in 0 ..< Self.maximumVocabularySize {
            guard let raw = tokenizer.convertIdToToken(id) else {
                pieces.append(nil)
                if sawToken { missingRun += 1 }
                if sawToken, missingRun >= Self.terminalMissingRun {
                    pieces.removeLast(missingRun)
                    break
                }
                continue
            }
            sawToken = true
            missingRun = 0
            pieces.append(Self.decodePiece(raw))
        }
        guard !pieces.isEmpty else {
            throw ToolConstraintSchemaError.invalid(
                "tokenizer exposes no vocabulary")
        }

        var index = [[Int]](repeating: [], count: 256)
        var stringSafe: [Int] = []
        var nonStringSafe: [Int] = []
        var withoutLessThan: [Int] = []
        var withLessThan: [Int] = []
        for (id, piece) in pieces.enumerated() {
            guard let piece, let first = piece.first else { continue }
            index[Int(first)].append(id)
            if String(bytes: piece, encoding: .utf8) != nil,
                piece.allSatisfy({
                    (0x20 ... 0x3B).contains($0)
                        || (0x3D ... 0x7E).contains($0)
                        || $0 >= 0x80
                })
            {
                stringSafe.append(id)
            } else {
                nonStringSafe.append(id)
            }
            if piece.contains(0x3C) {
                withLessThan.append(id)
            } else {
                withoutLessThan.append(id)
            }
        }
        self.pieces = pieces
        self.byFirstByte = index
        self.stringSafeTokenIDs = stringSafe
        self.nonStringSafeTokenIDs = nonStringSafe
        self.tokensWithoutLessThan = withoutLessThan
        self.tokensWithLessThan = withLessThan
        self.stopTokenIDs = stopTokenIDs
        self.fallbackTokenID = fallback
    }

    private static let allowedSpecialTokens: Set<String> = [
        "<|tool_call>", "<tool_call|>", "<|\"|>",
    ]

    private static func decodePiece(_ raw: String) -> [UInt8]? {
        if raw.count == 6, raw.hasPrefix("<0x"), raw.hasSuffix(">"),
            let byte = UInt8(raw.dropFirst(3).dropLast(), radix: 16)
        {
            return [byte]
        }
        if raw.hasPrefix("<"), raw.hasSuffix(">"),
            !allowedSpecialTokens.contains(raw)
        {
            return nil
        }
        return Array(raw.replacingOccurrences(of: "▁", with: " ").utf8)
    }
}
