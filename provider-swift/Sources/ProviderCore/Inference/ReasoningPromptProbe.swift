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
//
// The SAME `undecided` state also buffers TAGLESS output whole: a model
// that never emits a think tag (qwen3-vl instruct, Qwen3.x with thinking
// disabled, media requests) leaves the parser undecided until
// end-of-stream, so the consumer's first content delta arrives when
// generation ENDS — TTFT equals the whole generation time. The provider
// knows something the parser cannot infer from output alone: when the
// prompt did NOT pre-open a think block, an orphan `</think>` cannot
// legitimately occur, so the parser should stream immediately. For that
// case the engine injects the empty pair `<think></think>`: the parser
// walks `undecided → reasoning → content` emitting nothing (both spans
// are empty) and is then in its marker-safe `content` state — tagless
// text streams per token, and a model that later emits its own
// `<think>…</think>` still flips to reasoning.

import MLXLMServer

enum ReasoningPromptProbe {
    /// The synthetic opening marker injected into the event stream.
    static let thinkOpen = "<think>"

    /// The synthetic empty pair injected when the prompt did NOT pre-open a
    /// think block: two pure parser state transitions, nothing emitted.
    static let thinkEmptyPair = "<think></think>"

    /// What the engine should inject ahead of the model's output.
    enum Injection: Equatable, Sendable {
        /// The rendered prompt pre-opened a think block (output carries
        /// only the close) → inject `<think>`.
        case preOpened
        /// A think-format parser will consume the stream but the prompt did
        /// not pre-open a block → inject `<think></think>` so tagless
        /// output streams per token instead of buffering until the end.
        case notPreOpened
        /// Nothing to inject: no think-format parser downstream (a marker
        /// would leak verbatim), a non-streaming request (the collector
        /// classifies at completion), or a tail with an unclosed open tag
        /// mid-tail (injecting would leak the model's orphan close).
        case inapplicable

        /// The synthetic `.content` text to yield, nil for `.inapplicable`.
        var marker: String? {
            switch self {
            case .preOpened: return ReasoningPromptProbe.thinkOpen
            case .notPreOpened: return ReasoningPromptProbe.thinkEmptyPair
            case .inapplicable: return nil
            }
        }
    }

    /// Prompt-tail tokens to decode for the probe. The open tag sits in
    /// the last few tokens of the rendered template
    /// (`<|im_start|>assistant\n<think>\n`), so 8 is generous while
    /// keeping the decode O(1) regardless of prompt length.
    ///
    /// Residual edge: an assistant prefill longer than 8 tokens INSIDE an
    /// open `<think>` would slip past `tailHasUnclosedThinkOpen` and read
    /// as `.notPreOpened`. Unreachable via the public API today (no
    /// continue-final-message path renders such a tail).
    static let tailTokenCount = 8

    /// Which synthetic marker (if any) the engine should inject ahead of the
    /// model's output for this request.
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
    /// - The rendered prompt's decoded tail decides between `.preOpened`
    ///   (ends inside an open think block) and `.notPreOpened` (anything
    ///   else, including the pre-CLOSED thinking-off tail and an empty
    ///   prompt — neither can produce an orphan close). An open tag
    ///   mid-tail that is never closed is `.inapplicable` (see below).
    static func injection(
        reasoningParser: ReasoningParserFormat?,
        stream: Bool?,
        promptTokens: [Int],
        decodeTail: ([Int]) -> String
    ) -> Injection {
        guard reasoningParser == .qwen3 || reasoningParser == .deepseekR1 else {
            return .inapplicable
        }
        guard stream == true else { return .inapplicable }
        guard !promptTokens.isEmpty else { return .notPreOpened }
        let tail = decodeTail(Array(promptTokens.suffix(tailTokenCount)))
        if promptEndsInsideThinkBlock(tail) { return .preOpened }
        // An open tag somewhere in the tail that is never closed means the
        // prompt DID pre-open a block but the turn continues past the tag
        // (assistant prefill inside reasoning). Injecting the empty pair
        // there would make the model's orphan `</think>` leak as content,
        // so fall back to no injection: the parser buffers until the close
        // — slower, but correct.
        if tailHasUnclosedThinkOpen(tail) { return .inapplicable }
        return .notPreOpened
    }

    /// True when the tail contains a `<think>` with no `</think>` after it.
    static func tailHasUnclosedThinkOpen(_ tail: String) -> Bool {
        guard let open = tail.range(of: thinkOpen, options: .backwards) else { return false }
        return tail[open.upperBound...].range(of: "</think>") == nil
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
