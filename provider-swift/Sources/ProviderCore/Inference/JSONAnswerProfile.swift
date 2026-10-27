// Copyright © 2026 Eigen Labs.

import Foundation

/// Output phase of a constrained JSON answer.
enum JSONAnswerPhase: Hashable, Sendable {
    /// Prompt-opened reasoning: free text until the profile's close marker,
    /// with every EOS masked.
    case reasoning
    /// One JSON value of the compiled grammar, then an answer EOS.
    case answer
}

/// Family framing around a constrained JSON answer: reasoning markers, the
/// spellings the answer may never complete, and the pinned token contract the
/// loaded tokenizer must match before anything is constrained.
struct JSONAnswerProfile: Sendable {
    struct PinnedToken: Sendable {
        let spelling: String
        let id: Int
    }

    /// Content-free family name for messages and logs.
    let family: String
    /// The one marker that ends reasoning.
    let thinkClose: [UInt8]
    /// Scanned while reasoning: `thinkClose` ends it and any other completed
    /// marker is refused, so reasoning never spells a turn or stop marker.
    let reasoningMarkers: [[UInt8]]
    /// No answer byte sequence may complete one of these, however tokenized.
    let contentMarkers: [[UInt8]]
    /// Ids below this are byte-level BPE pieces; added tokens start here.
    let firstAddedTokenID: Int
    /// Added tokens that are ordinary output pieces: the reasoning markers.
    let pieceTokens: [PinnedToken]
    /// Answer terminators; the first is the impossible-state fallback. Each
    /// must also be an engine stop token.
    let answerEOS: [PinnedToken]
    /// Ids considered for pieces: the model's vocabulary. Ids without a piece,
    /// including padding beyond the tokenizer, are never allowed.
    let vocabularySize: Int

    init(family: String, thinkClose: String, reasoningStops: [String], contentMarkers: [String],
         firstAddedTokenID: Int, pieceTokens: [PinnedToken], answerEOS: [PinnedToken], vocabularySize: Int) {
        self.family = family
        self.thinkClose = Array(thinkClose.utf8)
        reasoningMarkers = ([thinkClose] + reasoningStops).map { Array($0.utf8) }
        self.contentMarkers = contentMarkers.map { Array($0.utf8) }
        self.firstAddedTokenID = firstAddedTokenID
        self.pieceTokens = pieceTokens
        self.answerEOS = answerEOS
        self.vocabularySize = vocabularySize
    }

    /// Phase in which output starts after the rendered prompt: an open think
    /// block starts in reasoning, a closed one in the answer. Nil for any
    /// other boundary, which is then not constrained.
    func initialPhase(promptTail: String) -> JSONAnswerPhase? {
        guard let prefix = ReasoningPromptProbe.streamingPrefix(forPromptTail: promptTail) else { return nil }
        return prefix == ReasoningPromptProbe.thinkOpen ? .reasoning : .answer
    }
}

extension JSONAnswerProfile {
    /// Qwen 3.5, 3.6 and 3.8 (`qwen3_5`, `qwen3_5_moe`): byte-level BPE below
    /// `<|endoftext|>`, the think markers as added tokens, and answers that
    /// end with `<|im_end|>` or `<|endoftext|>`. The model's vocabulary pads
    /// the 248,077 tokenizer ids to 248,320.
    static let qwen35 = JSONAnswerProfile(
        family: "Qwen",
        thinkClose: "</think>",
        reasoningStops: ["<|im_end|>", "<|endoftext|>", "<|im_start|>"],
        contentMarkers: ["<think>", "</think>", "<tool_call>", "</tool_call>", "<function=",
                         "<|im_start|>", "<|im_end|>", "<|endoftext|>"],
        firstAddedTokenID: 248044,
        pieceTokens: [.init(spelling: "<think>", id: 248068), .init(spelling: "</think>", id: 248069)],
        answerEOS: [.init(spelling: "<|im_end|>", id: 248046), .init(spelling: "<|endoftext|>", id: 248044)],
        vocabularySize: 248320)
}
