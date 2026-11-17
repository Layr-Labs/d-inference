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
    /// Ids of the byte-level BPE pieces. Every other id (special and added
    /// tokens, padding beyond the tokenizer) has no piece unless it is pinned
    /// below.
    let bpeIDs: Range<Int>
    /// Added tokens that are ordinary output pieces: the think markers.
    let pieceTokens: [PinnedToken]
    /// Answer terminators; the first is the impossible-state fallback. Each
    /// must also be an engine stop token.
    let answerEOS: [PinnedToken]
    /// Ids considered for pieces: the model's vocabulary. Ids without a piece,
    /// including padding beyond the tokenizer, are never allowed.
    let vocabularySize: Int
    /// Whether a prompt that opens a thought is constrained too. A constrained
    /// row never drafts, and on a target without the row-exact recurrent
    /// fallback no row in its decode step does, so families admitted for their
    /// answers alone keep a reasoning-first request prompt-only.
    let constrainsReasoning: Bool

    init(family: String, thinkClose: String, reasoningStops: [String], contentMarkers: [String],
         bpeIDs: Range<Int>, pieceTokens: [PinnedToken], answerEOS: [PinnedToken], vocabularySize: Int,
         constrainsReasoning: Bool = true) {
        precondition(bpeIDs.lowerBound >= 0 && bpeIDs.upperBound <= vocabularySize,
                     "\(family) BPE ids must lie inside the model's vocabulary")
        self.family = family
        self.thinkClose = Array(thinkClose.utf8)
        reasoningMarkers = ([thinkClose] + reasoningStops).map { Array($0.utf8) }
        self.contentMarkers = contentMarkers.map { Array($0.utf8) }
        self.bpeIDs = bpeIDs
        self.pieceTokens = pieceTokens
        self.answerEOS = answerEOS
        self.vocabularySize = vocabularySize
        self.constrainsReasoning = constrainsReasoning
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
    /// the tokenizer's ids to 248,320.
    static let qwen35 = JSONAnswerProfile(
        family: "Qwen",
        thinkClose: "</think>",
        reasoningStops: ["<|im_end|>", "<|endoftext|>", "<|im_start|>"],
        contentMarkers: qwen35ContentMarkers,
        bpeIDs: 0..<248044,
        pieceTokens: qwen35PieceTokens,
        answerEOS: [.init(spelling: "<|im_end|>", id: 248046), .init(spelling: "<|endoftext|>", id: 248044)],
        vocabularySize: 248320)

    /// PrismML Bonsai 2 27B (`prism_hadamard_qwen35`) ships Qwen 3.5's
    /// tokenizer and chat template, so Qwen's ids under its own name. Its
    /// artifact declares `<|im_end|>` alone as EOS, so that is the one
    /// terminator; an engine that also stops at `<|endoftext|>` never samples
    /// it here. Only answer-first prompts are constrained, as on Lightning: the
    /// JSON default renders thinking off, and its thinking answers met the
    /// schema unconstrained.
    static let bonsai2 = JSONAnswerProfile(
        family: "Bonsai",
        thinkClose: "</think>",
        reasoningStops: ["<|im_end|>", "<|endoftext|>", "<|im_start|>"],
        contentMarkers: qwen35ContentMarkers,
        bpeIDs: 0..<248044,
        pieceTokens: qwen35PieceTokens,
        answerEOS: [.init(spelling: "<|im_end|>", id: 248046)],
        vocabularySize: 248320,
        constrainsReasoning: false)

    private static let qwen35ContentMarkers = ["<think>", "</think>", "<tool_call>", "</tool_call>", "<function=",
                                               "<|im_start|>", "<|im_end|>", "<|endoftext|>"]
    private static let qwen35PieceTokens: [PinnedToken] = [.init(spelling: "<think>", id: 248068),
                                                           .init(spelling: "</think>", id: 248069)]

    /// Nemotron 3.5 Lightning (`nemotron_h`): its 1,000 special and added
    /// tokens come first (the think markers among them are ordinary output
    /// pieces), byte-level BPE pieces fill the rest of the 131,072 ids, and
    /// answers end with `<|im_end|>` or `</s>`, the checkpoint's two EOS ids.
    /// `</s>` has no piece, so its spelling (an HTML close tag) stays writable.
    /// Only answer-first prompts are constrained: Lightning drafts, and its
    /// reasoning runs to thousands of tokens.
    static let nemotron35 = JSONAnswerProfile(
        family: "Nemotron",
        thinkClose: "</think>",
        reasoningStops: ["<|im_end|>", "<|im_start|>"],
        contentMarkers: ["<think>", "</think>", "<tool_call>", "</tool_call>", "<function=",
                         "<|im_start|>", "<|im_end|>"],
        bpeIDs: 1000..<131072,
        pieceTokens: [.init(spelling: "<think>", id: 12), .init(spelling: "</think>", id: 13)],
        answerEOS: [.init(spelling: "<|im_end|>", id: 11), .init(spelling: "</s>", id: 2)],
        vocabularySize: 131072,
        constrainsReasoning: false)

    /// GLM-5.3-Flash (`glm5_next`): byte-level BPE below `<|endoftext|>`, its
    /// 36 added tokens above (the think markers among them are ordinary output
    /// pieces), and answers that end with `<|user|>` or `<|endoftext|>`, two of
    /// the artifact's three EOS ids. The model's vocabulary pads the tokenizer's
    /// 154,856 ids to 154,880. Reasoning-first prompts (GLM's JSON default) are
    /// constrained too; such a row drafts under grammar-aware verification where
    /// `DARKBLOOM_CBV2_MTP_GRAMMAR` is on (the GLM build's default), else it
    /// decodes target-only throughout.
    static let glm5Next = JSONAnswerProfile(
        family: "GLM",
        thinkClose: "</think>",
        reasoningStops: ["<|endoftext|>", "<|user|>", "<|assistant|>", "<|system|>", "<|observation|>"],
        contentMarkers: ["<think>", "</think>", "<tool_call>", "</tool_call>", "<arg_key>", "</arg_key>",
                         "<arg_value>", "</arg_value>", "<|endoftext|>", "<|user|>", "<|assistant|>", "<|system|>",
                         "<|observation|>"],
        bpeIDs: 0..<154820,
        pieceTokens: [.init(spelling: "<think>", id: 154841), .init(spelling: "</think>", id: 154842)],
        answerEOS: [.init(spelling: "<|user|>", id: 154827), .init(spelling: "<|endoftext|>", id: 154820)],
        vocabularySize: 154880)

    /// GPT-OSS (`gpt_oss`, o200k Harmony): the arguments of a forced call
    /// (`GPTOSSForcedToolConstraint`). Byte-level BPE below `<|startoftext|>`;
    /// the Harmony control tokens above it are never pieces, and no argument
    /// may spell one. Arguments end with `<|call|>`. The model's vocabulary
    /// pads the tokenizer's 200,019 ids to 201,088.
    static let gptOSS = JSONAnswerProfile(
        family: "GPT-OSS",
        thinkClose: "<|end|>",
        reasoningStops: harmonyMarkers,
        contentMarkers: harmonyMarkers,
        bpeIDs: 0..<199998,
        pieceTokens: [],
        answerEOS: [.init(spelling: "<|call|>", id: 200012)],
        vocabularySize: 201088)

    /// The Harmony spellings the stream's parsers read as framing.
    static let harmonyMarkers = [
        "<|start|>", "<|end|>", "<|message|>", "<|channel|>", "<|constrain|>", "<|return|>", "<|call|>",
        "<|endoftext|>", "<|startoftext|>", "<|endofprompt|>",
    ]
}
