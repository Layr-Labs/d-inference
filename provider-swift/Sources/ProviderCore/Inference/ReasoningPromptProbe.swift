// Copyright © 2026 Eigen Labs.
//
// Detects prompts whose rendered chat template ends INSIDE an open
// <think> block. Qwen3.6 / DeepSeek-R1-style templates append
// `<think>\n` after the assistant header, so the model's OUTPUT carries
// only the closing `</think>` — never the opening tag.
//
// Why this matters for TTFT: the streaming think parser
// (`StreamingThinkReasoningParser`, MLXLMServer) can only stream
// reasoning deltas incrementally once it has SEEN an opening tag.
// Close-only output leaves it in its `undecided` state, where every
// token buffers until `</think>` arrives — the consumer's first delta
// (and thus TTFT) is delayed by the ENTIRE thinking duration.
//
// The fix: when the rendered prompt pre-opens a think block AND a
// think-format reasoning parser will consume this stream, the engine
// injects one synthetic `.content("<think>")` event ahead of the
// model's output (`MultiModelBatchSchedulerEngine.makeEventStream`).
// The parser consumes the marker as a pure state transition — nothing
// is emitted downstream — then streams `reasoning_content` deltas
// token-by-token.

import MLXLMServer

enum ReasoningPromptProbe {
    /// The synthetic opening marker injected into the event stream.
    static let thinkOpen = "<think>"

    /// Prompt-tail tokens to decode for the probe. The open tag sits in
    /// the last few tokens of the rendered template
    /// (`<|im_start|>assistant\n<think>\n`), so 8 is generous while
    /// keeping the decode O(1) regardless of prompt length.
    static let tailTokenCount = 8

    /// Whether the engine should inject a synthetic `<think>` open ahead
    /// of the model's output for this request.
    ///
    /// Gates, in order:
    /// - A think-format parser (`.qwen3` / `.deepseekR1`) must be active
    ///   downstream. A `.none`/unset parser passes chunks through
    ///   verbatim, so an injected marker would leak to the consumer as
    ///   literal content. (The coordinator path always sets the parser —
    ///   `ProviderLoop.inferReasoningParser` fills nil.)
    /// - Streaming only. The non-streaming collector's `ReasoningParser`
    ///   already classifies close-only output correctly at completion;
    ///   only the streaming path suffers the buffering.
    /// - The rendered prompt's decoded tail must end inside an open
    ///   think block.
    static func shouldSynthesizeThinkOpen(
        reasoningParser: ReasoningParserFormat?,
        stream: Bool?,
        promptTokens: [Int],
        decodeTail: ([Int]) -> String
    ) -> Bool {
        guard reasoningParser == .qwen3 || reasoningParser == .deepseekR1 else { return false }
        guard stream == true else { return false }
        guard !promptTokens.isEmpty else { return false }
        return promptEndsInsideThinkBlock(decodeTail(Array(promptTokens.suffix(tailTokenCount))))
    }

    /// True when the tail ends with an unclosed `<think>` (ignoring
    /// trailing whitespace). A template that embeds a pre-CLOSED empty
    /// block (`<think>\n\n</think>` — thinking disabled) ends with
    /// `</think>` and is correctly rejected: `"</think>"` does not have
    /// the suffix `"<think>"`.
    static func promptEndsInsideThinkBlock(_ tail: String) -> Bool {
        var trimmed = Substring(tail)
        while let last = trimmed.last, last.isWhitespace {
            trimmed.removeLast()
        }
        return trimmed.hasSuffix(thinkOpen)
    }
}
