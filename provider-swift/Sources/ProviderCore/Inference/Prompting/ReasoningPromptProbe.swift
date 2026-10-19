// Copyright © 2026 Eigen Labs.
//
// Seed the think parser from the rendered generation prompt.
// Qwen/DeepSeek templates can leave a think block open, or close an empty
// block when thinking is disabled (the default for media). Those markers
// belong to the prompt, so the generated output need not repeat them.
// Collected and streaming requests both need this prompt-side state; a
// token limit may stop generation before the model closes the block.
//
// The engine sends the returned prefix before model output. The selected
// think parser consumes it only as a state transition: no content, usage,
// or synthetic reasoning reaches the consumer.

import MLXLMServer

enum ReasoningPromptProbe {
    static let thinkOpen = "<think>"
    static let thinkClose = "</think>"

    /// Both the open and the pre-closed empty block fit in the final few
    /// template tokens. Keep decode O(1) regardless of prompt length.
    static let tailTokenCount = 8

    /// Seed think-format parsers for collected and streaming requests. Explicit
    /// `.none`, other families, and unknown tails retain their existing behavior.
    /// The engine produces an event stream even for collected HTTP requests;
    /// HTTP delivery mode does not change the prompt-side parser state.
    /// ProviderLoop resolves an omitted parser before calling the engine.
    static func streamingPrefix(
        reasoningParser: ReasoningParserFormat?,
        stream _: Bool?,
        promptTokens: [Int],
        decodeTail: ([Int]) -> String
    ) -> String? {
        guard reasoningParser == .qwen3 || reasoningParser == .deepseekR1 else { return nil }
        guard !promptTokens.isEmpty else { return nil }
        return streamingPrefix(forPromptTail: decodeTail(Array(promptTokens.suffix(tailTokenCount))))
    }

    static func streamingPrefix(forPromptTail tail: String) -> String? {
        var trimmed = Substring(tail)
        while let last = trimmed.last, last.isWhitespace {
            trimmed.removeLast()
        }
        if trimmed.hasSuffix(thinkOpen) { return thinkOpen }
        // A completed prompt-side block means output starts in content
        // mode. An empty synthetic block advances the existing parser
        // there without flushing prompt text as reasoning or answer text.
        if trimmed.hasSuffix(thinkClose) { return thinkOpen + thinkClose }
        return nil
    }
}
