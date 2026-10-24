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

import Foundation
import MLXLMServer

enum ReasoningPromptProbe {
    static let thinkOpen = "<think>"
    static let thinkClose = "</think>"

    /// Both the open and the pre-closed empty block fit in the final few
    /// template tokens. Keep decode O(1) regardless of prompt length.
    static let tailTokenCount = 8

    /// `DARKBLOOM_TTFT_THINK_CONTENT_SEED=0` restores the undecided parser
    /// for `plainTailContentModelTypes` prompts whose tail carries no think
    /// marker.
    static let plainTailContentSeedEnvironmentKey = "DARKBLOOM_TTFT_THINK_CONTENT_SEED"
    static let seedsPlainTailContentByDefault =
        ProcessInfo.processInfo.environment[plainTailContentSeedEnvironmentKey] != "0"

    /// Model types whose plain generation prompt means the answer starts in
    /// content. Qwen3-VL Instruct renders a bare `<|im_start|>assistant\n`
    /// and never reasons; Qwen3-VL Thinking opens `<think>` in the prompt,
    /// which the tail check handles first. Other Qwen types stay undecided:
    /// Qwen 3.5, 3.6 and 3.8 templates always end in a marker, and a
    /// close-only reasoner such as `qwen3_next` writes its reasoning before
    /// a bare `</think>`, so a content seed would expose it as answer text.
    static let plainTailContentModelTypes: Set<String> = ["qwen3_vl_moe"]

    /// Seed think-format parsers for collected and streaming requests. Explicit
    /// `.none`, other families, and unrecognized prompt tails outside the
    /// plain-tail case below retain their existing behavior. The engine
    /// produces an event stream even for collected HTTP requests; HTTP
    /// delivery mode does not change the prompt-side parser state.
    /// ProviderLoop resolves an omitted parser before calling the engine.
    ///
    /// A `plainTailContentModelTypes` prompt with no think marker starts in
    /// content on the `qwen3` parser; undecided parsing would hold the whole
    /// answer until EOS. A `<think>` the model emits still opens reasoning.
    static func streamingPrefix(
        reasoningParser: ReasoningParserFormat?,
        stream _: Bool?,
        promptTokens: [Int],
        modelType: String? = nil,
        seedsPlainTailContent: Bool = seedsPlainTailContentByDefault,
        decodeTail: ([Int]) -> String
    ) -> String? {
        guard reasoningParser == .qwen3 || reasoningParser == .deepseekR1 else { return nil }
        guard !promptTokens.isEmpty else { return nil }
        if let prefix = streamingPrefix(forPromptTail: decodeTail(Array(promptTokens.suffix(tailTokenCount)))) {
            return prefix
        }
        guard seedsPlainTailContent, reasoningParser == .qwen3,
            let modelType = modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            plainTailContentModelTypes.contains(modelType)
        else { return nil }
        return thinkOpen + thinkClose
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
