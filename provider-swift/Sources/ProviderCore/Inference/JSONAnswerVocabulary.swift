// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// Byte-level vocabulary of one JSON-answer profile. Base BPE ids and the
/// profile's marker tokens carry pieces; every other id (special and added
/// tokens, padding up to the model's vocabulary) has none and is never
/// allowed. Built only when the tokenizer matches the pinned contract.
final class JSONAnswerVocabulary: ByteOrderedPieceVocabulary, Sendable {
    /// Indexed by token id; empty for ids that are never allowed.
    let pieces: [[UInt8]]
    let stopTokenIDs: Set<Int>
    /// Sorted answer terminators, all engine stop tokens.
    let answerEOS: [Int]
    /// The profile's first answer EOS, sampled only on an impossible state.
    let fallbackTokenID: Int
    /// Every non-stop id with a piece, ascending.
    let pieceTokenIDs: [Int]
    /// Pieces holding a reasoning marker's final byte: the only ones that can
    /// complete a marker while reasoning.
    let reasoningSensitive: [Int]
    /// Pieces that can leave a free JSON string body (quote, backslash, C0)
    /// or complete a content marker.
    let stringSensitive: [Int]
    let byteOrderedTokenIDs: [Int32]

    private struct Key: Hashable {
        let family: String
        let stops: Set<Int>
    }
    private static let cache = TokenizerVocabularyCache<Key, JSONAnswerVocabulary>(capacity: 4)

    static func cached(for handle: TokenizerHandle, profile: JSONAnswerProfile,
                       stopTokenIDs: Set<Int>) throws -> JSONAnswerVocabulary {
        try cache.value(for: handle, key: Key(family: profile.family, stops: stopTokenIDs)) {
            try JSONAnswerVocabulary(tokenizer: handle.inner, profile: profile, stopTokenIDs: stopTokenIDs)
        }
    }

    /// Verifies every pinned marker and terminator by id, spelling, encoding
    /// and decoding, and that every base id is a byte-level piece.
    convenience init(tokenizer: any MLXLMCommon.Tokenizer, profile: JSONAnswerProfile,
                     stopTokenIDs: Set<Int>) throws {
        for token in profile.pieceTokens + profile.answerEOS {
            guard tokenizer.convertTokenToId(token.spelling) == token.id,
                  tokenizer.convertIdToToken(token.id) == token.spelling,
                  tokenizer.encode(text: token.spelling, addSpecialTokens: false) == [token.id],
                  tokenizer.decode(tokenIds: [token.id], skipSpecialTokens: false) == token.spelling else {
                throw ToolConstraintSchemaError.invalid(
                    "\(profile.family) vocabulary does not match the pinned marker contract")
            }
        }
        var pieces = [[UInt8]](repeating: [], count: profile.vocabularySize)
        for id in 0..<profile.firstAddedTokenID {
            guard let raw = tokenizer.convertIdToToken(id), let bytes = ByteLevelBPE.bytes(raw), !bytes.isEmpty else {
                throw ToolConstraintSchemaError.invalid("Incomplete \(profile.family) byte-level vocabulary")
            }
            pieces[id] = bytes
        }
        for token in profile.pieceTokens { pieces[token.id] = Array(token.spelling.utf8) }
        try self.init(pieces: pieces, profile: profile, stopTokenIDs: stopTokenIDs)
    }

    /// Small vocabularies also exercise the production machine in CPU-only
    /// tests, without a tokenizer, model or MLX array.
    init(pieces: [[UInt8]], profile: JSONAnswerProfile, stopTokenIDs: Set<Int>) throws {
        let terminators = profile.answerEOS.map(\.id)
        guard let fallback = terminators.first, Set(terminators).isSubset(of: stopTokenIDs),
              terminators.allSatisfy(pieces.indices.contains),
              profile.pieceTokens.allSatisfy({
                  pieces.indices.contains($0.id) && pieces[$0.id] == Array($0.spelling.utf8)
              }) else {
            throw ToolConstraintSchemaError.invalid(
                "\(profile.family) JSON answers require the pinned markers and answer EOS among the stop tokens")
        }
        let reasoningFinals = Set(profile.reasoningMarkers.compactMap(\.last))
        let contentFinals = Set(profile.contentMarkers.compactMap(\.last))
        let usable = pieces.indices.filter { !pieces[$0].isEmpty && !stopTokenIDs.contains($0) }
        self.pieces = pieces
        self.stopTokenIDs = stopTokenIDs
        answerEOS = terminators.sorted()
        fallbackTokenID = fallback
        pieceTokenIDs = usable
        reasoningSensitive = usable.filter { pieces[$0].contains(where: reasoningFinals.contains) }
        stringSensitive = usable.filter { id in
            pieces[id].contains { $0 < 0x20 || $0 == 34 || $0 == 92 || contentFinals.contains($0) }
        }
        byteOrderedTokenIDs = usable.sorted { pieces[$0].lexicographicallyPrecedes(pieces[$1]) }.map { Int32($0) }
    }
}
