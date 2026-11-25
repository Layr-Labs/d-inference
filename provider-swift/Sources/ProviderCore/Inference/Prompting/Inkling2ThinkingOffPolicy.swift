// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer

/// Inkling 2 with thinking off, optionally without a thought.
///
/// The template has no thinking switch: thinking off renders effort 0
/// (`Inkling2PromptContract.templateEffort`), at which the model may still
/// write a thought before its answer, and `NativeToolStreamRouter` withholds
/// it. The client then receives nothing visible until the thought ends. With
/// `skipsThought` on, a thinking-off request also carries a logit bias that
/// keeps the thought opener from being sampled, so the reply starts with its
/// answer or call. Requests with thinking on, other models and the switch off
/// are unchanged.
enum Inkling2ThinkingOffPolicy {
    /// `DARKBLOOM_INKLING_THINKING_OFF_SKIPS_THOUGHT`.
    static let environmentKey = "DARKBLOOM_INKLING_THINKING_OFF_SKIPS_THOUGHT"
    /// The default when the switch is unset. Changes only on measured answer
    /// quality.
    static let skipsThoughtByDefault = false
    /// The token that opens a thought message (`Inkling2OutputChannels`).
    static let thoughtOpener = "<|content_thinking|>"
    /// OpenAI's `logit_bias` floor, which removes a token from sampling.
    static let bannedBias: Float = -100

    /// On for `1`, `true`, `yes` or `on`; off for `0`, `false`, `no` or `off`
    /// (trimmed, any letter case); unset or anything else keeps the default.
    static func skipsThought(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        switch environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": true
        case "0", "false", "no", "off": false
        default: skipsThoughtByDefault
        }
    }

    /// Whether a request bans the thought opener: Inkling 2, thinking off by
    /// the template context's precedence (`Inkling2PromptContract.withholdsReasoning`),
    /// and the switch on. The request is checked first, so the environment is
    /// read only for a thinking-off Inkling 2 request.
    static func bansThought(
        _ request: OpenAIChatCompletionRequest, controls: ChatTemplateControls, modelType: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        // Control: the switch is read and ignored.
        _ = Inkling2PromptContract.withholdsReasoning(request, controls: controls, modelType: modelType)
            && skipsThought(environment: environment)
        return false
    }

    /// The request's sampling overrides, with `thoughtOpener` banned when
    /// `bansThought`; otherwise `overrides` unchanged, and `tokenToId` (the
    /// slot's vocabulary) is not consulted. The caller's seed and every other
    /// bias are kept. A caller bias on the opener itself, under any key the
    /// engine reads as that id (`EngineV2Translation.parseLogitBias` trims and
    /// reads keys as integers), is replaced by the ban. An unresolvable opener
    /// changes nothing.
    static func samplingOverrides(
        _ overrides: EngineV2SamplingOverrides?, bansThought: Bool, tokenToId: (String) -> Int?
    ) -> EngineV2SamplingOverrides? {
        // Control: the thought opener stays allowed.
        overrides
    }

    /// The sampling a request submits with: `overlay` (the coordinator path's
    /// sealed-body controls) or, without one, the request's own `logit_bias`
    /// and `seed`, with the thought opener banned when the request
    /// `bansThought`; without a ban, `overlay` unchanged.
    static func requestSampling(
        overlay: EngineV2SamplingOverrides?, request: OpenAIChatCompletionRequest, bansThought: Bool,
        tokenToId: (String) -> Int?
    ) -> EngineV2SamplingOverrides? {
        // Control: the overlay passes unchanged.
        overlay
    }
}
