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
/// answer or call; a thought that still starts another way is withheld as
/// before. Requests with thinking on, other models and the switch off are
/// unchanged.
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

    /// The switch as this process read it, once, at first use: siblings such
    /// as `DARKBLOOM_INKLING_MTP_COUPLED` are read at load, not per request.
    /// Task-local so a test can set it around one request.
    @TaskLocal static var switchedOn = skipsThought()

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
    /// and the switch on (`switchedOn`, read once per process).
    static func bansThought(
        _ request: OpenAIChatCompletionRequest, controls: ChatTemplateControls, modelType: String?,
        switchedOn: Bool = Inkling2ThinkingOffPolicy.switchedOn
    ) -> Bool {
        switchedOn && Inkling2PromptContract.withholdsReasoning(request, controls: controls, modelType: modelType)
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
        guard bansThought, let opener = tokenToId(thoughtOpener), opener >= 0 else { return overrides }
        var bias = (overrides?.logitBias ?? [:]).filter {
            Int($0.key.trimmingCharacters(in: .whitespaces)) != opener
        }
        bias[String(opener)] = bannedBias
        return EngineV2SamplingOverrides(logitBias: bias, seed: overrides?.seed)
    }

    /// The sampling a request submits with. With `bansThought`, the thought
    /// opener is banned on `overlay` (the coordinator path's sealed-body
    /// controls) or, without one, on the request's own `logit_bias` and
    /// `seed`. Without a ban, `overlay` unchanged (nil on the local API, where
    /// `translate` falls back to the request's own fields), and `tokenToId` is
    /// not consulted.
    static func requestSampling(
        overlay: EngineV2SamplingOverrides?, request: OpenAIChatCompletionRequest, bansThought: Bool,
        tokenToId: (String) -> Int?
    ) -> EngineV2SamplingOverrides? {
        guard bansThought else { return overlay }
        let base = overlay ?? EngineV2SamplingOverrides(logitBias: request.logitBias, seed: request.seed)
        return samplingOverrides(base, bansThought: true, tokenToId: tokenToId)
    }
}
