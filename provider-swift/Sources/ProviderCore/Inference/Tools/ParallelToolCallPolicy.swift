// Copyright © 2026 Eigen Labs.

import MLXLMCommon

/// `parallel_tool_calls: false`: a response carries one call, the first. OpenAI
/// returns at most one, and vLLM keeps the first
/// (`maybe_filter_parallel_tool_calls`). The calls a model makes after it are
/// dropped instead of failing a response that may already have streamed the
/// first; no template reads the flag, so nothing in the prompt asked for one
/// call. `ToolConstraintValidation.validate` keeps its cardinality check as
/// defense in depth.
enum ParallelToolCallPolicy {
    /// The calls a response returns from those withheld until the end.
    static func admitted(_ calls: [ToolCall], prepared: ToolChoicePromptPolicy.Prepared) -> [ToolCall] {
        prepared.allowsParallelCalls ? calls : Array(calls.prefix(1))
    }

    /// Drops the streamed segments of every call after the first: a dropped
    /// frame is consumed, never exposed or validated.
    struct LaterCallFilter {
        private var droppingFrame = false

        /// `exposedCalls`: calls of this response already exposed.
        mutating func drops(
            _ segment: ToolCallStreamSegment, exposedCalls: Int, prepared: ToolChoicePromptPolicy.Prepared
        ) -> Bool {
            guard !prepared.allowsParallelCalls else { return false }
            switch segment {
            case .text:
                return false
            case .callStarted:
                droppingFrame = exposedCalls > 0
                return droppingFrame
            case .callArguments:
                return droppingFrame
            case .callCompleted, .callFailed:
                defer { droppingFrame = false }
                return droppingFrame
            case .call:
                return exposedCalls > 0
            }
        }
    }
}
