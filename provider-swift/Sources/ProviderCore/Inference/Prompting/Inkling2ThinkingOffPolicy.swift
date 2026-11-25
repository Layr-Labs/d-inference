// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer

/// Inkling 2 with thinking off, optionally without a thought.
///
/// The template has no thinking switch: thinking off renders effort 0
/// (`Inkling2PromptContract.templateEffort`), at which the model still writes
/// a thought before its answer, and `NativeToolStreamRouter` withholds it. The
/// client then receives nothing visible until the thought ends. With
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

    /// The request's sampling overrides, with the thought opener banned when
    /// `bansThought`; otherwise `overrides` unchanged. The caller's seed and
    /// every other bias are kept; a caller bias on the opener itself is
    /// replaced by the ban. An unresolvable opener changes nothing.
    static func samplingOverrides(
        _ overrides: EngineV2SamplingOverrides?, bansThought: Bool, openerID: () -> Int?
    ) -> EngineV2SamplingOverrides? {
        guard bansThought, let id = openerID(), id >= 0 else { return overrides }
        var bias = overrides?.logitBias ?? [:]
        bias[String(id)] = bannedBias
        return EngineV2SamplingOverrides(logitBias: bias, seed: overrides?.seed)
    }

    /// Whether a request bans the thought opener: Inkling 2, thinking off by
    /// the template context's precedence (`Inkling2PromptContract.withholdsReasoning`),
    /// and the switch on.
    static func bansThought(
        _ request: OpenAIChatCompletionRequest, controls: ChatTemplateControls, modelType: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        Inkling2PromptContract.withholdsReasoning(request, controls: controls, modelType: modelType)
            && skipsThought(environment: environment)
    }
}
