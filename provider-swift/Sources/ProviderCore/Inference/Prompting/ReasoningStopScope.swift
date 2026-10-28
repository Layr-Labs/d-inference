// Copyright © 2026 Eigen Labs.
//
// Client stop strings end the answer, never the reasoning before it. Matched
// against all generated text, a stop the model happened to write while it
// reasoned ended the request before any answer: finish_reason "stop",
// reasoning only, empty content. Each scope mirrors the request's reasoning
// parser, so text it returns as reasoning, and tool-call frames, never match.

import Foundation
import MLXLMCommon
import MLXLMServer

enum ReasoningStopScope {
    static let think = CBv2StopStringScope.Span(opener: "<think>", closers: ["</think>"])
    static let thinkToolCall = CBv2StopStringScope.Span(
        opener: "<tool_call>", closers: ["</tool_call>"])
    static let gemmaThought = CBv2StopStringScope.Span(opener: "<|channel>", closers: ["<channel|>"])
    static let gemmaToolCall = CBv2StopStringScope.Span(
        opener: "<|tool_call>", closers: ["<tool_call|>"])

    /// The scope for one request. `reasoningPrefix` is the prompt's
    /// `ReasoningPromptProbe` state: an open think block means output starts
    /// inside reasoning. nil keeps the model's scope (GPT-OSS's Harmony final
    /// channel) or, without a reasoning parser, whole-output matching.
    static func scope(
        reasoningParser: ReasoningParserFormat?, reasoningPrefix: String?
    ) -> CBv2StopStringScope? {
        switch reasoningParser {
        case .qwen3?, .deepseekR1?:
            return CBv2StopStringScope(
                excluding: [think, thinkToolCall],
                startingInside: reasoningPrefix == ReasoningPromptProbe.thinkOpen)
        case .gemma4?:
            return CBv2StopStringScope(excluding: [gemmaThought, gemmaToolCall])
        default:
            return nil
        }
    }
}
