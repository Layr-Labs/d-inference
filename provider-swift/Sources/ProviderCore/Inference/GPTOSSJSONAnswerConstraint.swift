// Copyright © 2026 Eigen Labs.
//
// JSON `response_format` answers on GPT-OSS (Harmony). The model reasons in its
// analysis channel as it does unconstrained. After that message the sampler
// admits only the plain answer header, then one JSON value of the request's
// format (a `JSONAnswerConstraint` in its answer phase), then `<|return|>`.

import Foundation
import MLXLMCommon

extension JSONAnswerProfile {
    /// Harmony control spellings. None may appear as text in a constrained
    /// answer: the stream's Harmony parser reads them as framing.
    static let gptOSSAnswerMarkers = [
        "<|start|>", "<|end|>", "<|message|>", "<|channel|>", "<|constrain|>", "<|return|>", "<|call|>",
        "<|endoftext|>", "<|startoftext|>", "<|endofprompt|>",
    ]

    /// GPT-OSS answers (`gpt_oss`, o200k Harmony): byte-level BPE below
    /// `<|startoftext|>`, Harmony control tokens above it and never pieces. The
    /// answer ends with `<|return|>`. The model's vocabulary pads the
    /// tokenizer's 200,019 ids to 201,088.
    static let gptOSSAnswer = JSONAnswerProfile(
        family: "GPT-OSS answer",
        thinkClose: "<|end|>",
        reasoningStops: gptOSSAnswerMarkers,
        contentMarkers: gptOSSAnswerMarkers,
        firstAddedTokenID: 199998,
        pieceTokens: [],
        answerEOS: [.init(spelling: "<|return|>", id: 200002)],
        vocabularySize: 201088)
}

/// The Harmony control token and exact header sequences of a constrained
/// answer, resolved from the loaded tokenizer and checked by round trip.
struct GPTOSSAnswerFraming: Sendable {
    /// Where the rendered prompt leaves the model: a new assistant message.
    static let promptBoundary = "<|start|>assistant"
    static let analysisHeaderText = "<|channel|>analysis<|message|>"
    static let answerHeaderText = "<|start|>assistant<|channel|>final<|message|>"

    let end: Int
    let analysisHeader: [Int]
    let answerHeader: [Int]

    init(tokenizer: any MLXLMCommon.Tokenizer, firstAddedTokenID: Int) throws {
        func control(_ spelling: String) throws -> Int {
            guard let id = tokenizer.convertTokenToId(spelling), id >= firstAddedTokenID,
                  tokenizer.convertIdToToken(id) == spelling,
                  tokenizer.encode(text: spelling, addSpecialTokens: false) == [id],
                  tokenizer.decode(tokenIds: [id], skipSpecialTokens: false) == spelling else {
                throw ToolConstraintSchemaError.invalid("GPT-OSS vocabulary does not match the Harmony control tokens")
            }
            return id
        }
        let start = try control("<|start|>"), channel = try control("<|channel|>"), message = try control("<|message|>")
        end = try control("<|end|>")
        func header(_ text: String, opener: Int, controls: Set<Int>) throws -> [Int] {
            let tokens = tokenizer.encode(text: text, addSpecialTokens: false)
            guard tokens.first == opener, tokens.last == message, tokens.filter({ $0 == message }).count == 1,
                  tokens.allSatisfy({ $0 < firstAddedTokenID || controls.contains($0) }),
                  tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false) == text else {
                throw ToolConstraintSchemaError.invalid("GPT-OSS tokenizer does not encode the Harmony headers exactly")
            }
            return tokens
        }
        analysisHeader = try header(Self.analysisHeaderText, opener: channel, controls: [channel, message])
        answerHeader = try header(Self.answerHeaderText, opener: start, controls: [start, channel, message])
    }
}

/// Token automaton of one constrained GPT-OSS answer (not implemented yet).
final class GPTOSSJSONAnswerConstraint: CBv2TokenConstraint, @unchecked Sendable {
    static let answerAllowance = 256

    let mode = CBv2TokenConstraintMode.auto
    let maxTokens: Int
    let initialState = 0
    let fallbackTokenID: Int
    let analysisReserve = 0
    let format: JSONAnswerFormat

    init(format: JSONAnswerFormat, tokenizer: any MLXLMCommon.Tokenizer, vocabulary: JSONAnswerVocabulary,
         profile: JSONAnswerProfile = .gptOSSAnswer, maxTokens: Int) throws {
        self.format = format
        self.maxTokens = maxTokens
        fallbackTokenID = vocabulary.fallbackTokenID
    }

    func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] { [] }

    func nextState(state: Int, tokenID: Int) -> Int? { nil }
}
