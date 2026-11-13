// Copyright © 2026 Eigen Labs.
//
// JSON `response_format` answers on Gemma 4: the API only (red). Nothing here
// constrains output yet.

import Foundation
import MLXLMCommon

extension JSONAnswerProfile {
    static let gemma4 = JSONAnswerProfile(
        family: "Gemma",
        thinkClose: GemmaAnswerPieces.thoughtClose,
        reasoningStops: [],
        contentMarkers: GemmaAnswerPieces.controlSpellings,
        firstAddedTokenID: 0,
        pieceTokens: [.init(spelling: GemmaAnswerPieces.thoughtOpen, id: 100),
                      .init(spelling: GemmaAnswerPieces.thoughtClose, id: 101)],
        answerEOS: [.init(spelling: "<turn|>", id: 106), .init(spelling: "<eos>", id: 1)],
        vocabularySize: 262_144)
}

enum GemmaAnswerPieces {
    static let thoughtOpen = "<|channel>"
    static let thoughtClose = "<channel|>"
    static let controlSpellings = [
        "<pad>", "<eos>", "<bos>", "<unk>", "<mask>", "<|tool>", "<tool|>", "<|tool_call>", "<tool_call|>",
        "<|tool_response>", "<tool_response|>", "<|\"|>", "<|think|>", "<|channel>", "<channel|>", "<|turn>",
        "<turn|>", "<|image>", "<|audio>", "<|image|>", "<|audio|>", "<image|>", "<audio|>", "<|video|>",
    ]

    static func bytes(_ raw: String) -> [UInt8]? { nil }

    static func cachedVocabulary(for handle: TokenizerHandle, stopTokenIDs: Set<Int>) throws -> JSONAnswerVocabulary {
        try vocabulary(tokenizer: handle.inner, stopTokenIDs: stopTokenIDs)
    }

    static func vocabulary(tokenizer: any MLXLMCommon.Tokenizer, profile: JSONAnswerProfile = .gemma4,
                           stopTokenIDs: Set<Int>) throws -> JSONAnswerVocabulary {
        throw ToolConstraintSchemaError.unsupported("Gemma JSON answers are not constrained")
    }
}

struct GemmaJSONAnswerBoundary: Hashable {
    enum Phase: Hashable {
        case opening
        case thought
        case answer
    }

    static let maximumWhitespaceRun = 64
}

final class GemmaJSONAnswerConstraint: CBv2TokenConstraint, @unchecked Sendable {
    static let defaultMaximumStates = 16_384

    let mode = CBv2TokenConstraintMode.auto
    let maxTokens: Int
    let initialState = 0
    let fallbackTokenID: Int
    let format: JSONAnswerFormat
    let initialPhase: GemmaJSONAnswerBoundary.Phase
    let maximumStates: Int

    init(format: JSONAnswerFormat, vocabulary: JSONAnswerVocabulary, profile: JSONAnswerProfile = .gemma4,
         initialPhase: GemmaJSONAnswerBoundary.Phase, maxTokens: Int,
         maximumStates: Int = defaultMaximumStates) throws {
        self.format = format
        self.initialPhase = initialPhase
        self.maxTokens = maxTokens
        self.maximumStates = maximumStates
        fallbackTokenID = vocabulary.fallbackTokenID
    }

    func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] { [] }
    func nextState(state: Int, tokenID: Int) -> Int? { nil }
    var cachedStateCount: Int { 0 }
}
