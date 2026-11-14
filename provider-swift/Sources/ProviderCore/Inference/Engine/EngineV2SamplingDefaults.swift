// Copyright © 2026 Eigen Labs.
//
// Artifact-declared sampling defaults (`generation_config.json`) for the v2
// engine path.
//
// Reference servers (vLLM, SGLang, the model card's own examples) apply a
// checkpoint's `generation_config.json` sampling values whenever a request
// omits them. The provider historically collapsed every omitted knob to the
// legacy greedy defaults (`temperature 0`, `top_p 1`, `top_k 0`,
// `repetition_penalty 1`). For Nemotron 3.5 Lightning that difference is
// observable: the artifact declares `temperature 1.0, top_p 0.95,
// do_sample true`. Applying those defaults aligns omitted-field requests
// with that configuration; tool-selection quality needs separate validation.
//
// Rules:
// * Applied ONLY to fields the request omits. Explicit request values
//   always win (`temperature: 0` still means greedy).
// * `seed`, `logit_bias`, the frequency penalty and `max_tokens` are
//   untouched; only a model-card default sets the presence penalty.
// * Gated per model family with explicit admission, like
//   `ToolChoiceEnforcementPolicy.nativeStructuredTarget`: the admitted Nemotron
//   and owned Bonsai 9B listings, native Flint and the exact GLM-5.3-Flash
//   identities (catalog `glm-5.3-flash` and the local qualification download)
//   honor their artifact defaults.
//   The catalog Qwen 3.5/3.6 builds take their model cards' thinking-mode
//   values instead of the greedy decoding that looped to `max_tokens`,
//   including the cards' presence penalty 1.5 (`qwen35CardDefaults`).
//   0.10.12 dropped it on Qwen3.5-9B, whose long answers then ran to
//   `max_tokens` about three times as often in production (5.5 % against
//   1.7 %); 0.10.13 gives it back (`DARKBLOOM_QWEN35_9B_PRESENCE_PENALTY=0`
//   is the rollback).
//   Muse Glimmer 30B takes its model card's values (`museGlimmerCardDefaults`).
//   Every other model keeps the legacy defaults byte-for-byte.
// * `do_sample: false` in the file means greedy (legacy), matching HF
//   semantics; an absent or unreadable file is legacy.
// * Resolved once at slot construction (like the stop-token set). The
//   sampler is not part of prompt or cache identity, so prefix-cache and
//   SSD checkpoint identity are unchanged. It still decides whether a row
//   speculates: the engine drafts no row with a repetition, frequency or
//   presence penalty (`EngineLoopV2.mtpBasicEligible`). On an opted-in
//   history-keeping MTP head such a row still stages the resident and SSD
//   checkpoints a speculating row stages (prefix-cache invariant 9).

import Foundation
import MLXLMCommon
#if canImport(os)
import os
#endif

public struct EngineV2SamplingDefaults: Sendable, Equatable {
    /// `nil` ⇒ the legacy contract value for that knob.
    public var temperature: Float?
    public var topP: Float?
    public var topK: Int?
    public var repetitionPenalty: Float?
    public var presencePenalty: Float?

    public init(
        temperature: Float? = nil, topP: Float? = nil, topK: Int? = nil,
        repetitionPenalty: Float? = nil, presencePenalty: Float? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repetitionPenalty = repetitionPenalty
        self.presencePenalty = presencePenalty
    }

    /// Legacy behavior: every omitted knob collapses to the contract's no-op
    /// value (temperature `0.0` = greedy, topP `1.0`, topK `0`,
    /// repetitionPenalty `1.0`) — exactly what `samplingParams(from:)`
    /// produced before artifact defaults existed.
    public static let legacy = EngineV2SamplingDefaults()

    /// The model cards' thinking-mode values (the template default), shared by
    /// these exact catalog builds and their `model_type`, with the cards'
    /// presence penalty. Without it qwen3.5-35b-a3b looped under typical and
    /// exact MTP acceptance alike, and Qwen3.5-9B's answers ran on to
    /// `max_tokens` (`qwen35NineBNoPenaltyDefaults`). A penalty row does not
    /// speculate; it still stages the prefix checkpoints a speculating row
    /// stages.
    static let qwen35CardDefaults = EngineV2SamplingDefaults(
        temperature: 1.0, topP: 0.95, topK: 20, presencePenalty: 1.5)
    /// Qwen3.5-9B under `DARKBLOOM_QWEN35_9B_PRESENCE_PENALTY=0`: the card's
    /// values without the penalty, 0.10.12's default. Its 31-draw gate saw no
    /// loop under exact acceptance. In production, 0.10.12 against 0.10.11
    /// Macs over the same period, its answers with `max_tokens` ≥ 8,192 ran
    /// to the limit about three times as often (5.5 % against 1.7 %), and
    /// its constrained JSON `response_format` rows, which never speculate,
    /// ran out and failed about twice as often (51 % against 23 % in the same
    /// 10-minute windows). The penalty is the difference we can establish:
    /// with nothing else running those rows failed 32.7 % against 13.6 %.
    /// The registry's `presence_penalty` 1.5 restored it on 2026-11-12.
    static let qwen35NineBNoPenaltyDefaults = EngineV2SamplingDefaults(
        temperature: 1.0, topP: 0.95, topK: 20)
    static let qwen35NineBModelID = "Qwen3.5-9B"

    /// Muse Glimmer 30B's model-card values. The NVIDIA NVFP4 repository's
    /// `generation_config.json` declares `do_sample: false`; the card, and the
    /// base repository's own file, give these. A reasoning model decoded
    /// greedily is outside what the card evaluates, so the exact identity
    /// takes them whatever that file says.
    static let museGlimmerCardDefaults = EngineV2SamplingDefaults(
        temperature: 1.0, topP: 0.95, topK: 64)

    /// `DARKBLOOM_QWEN35_9B_PRESENCE_PENALTY`: `0`, `off`, `false` or `no`
    /// (trimmed, case-insensitive) restores 0.10.12's no-penalty default for
    /// Qwen3.5-9B requests that omit a presence penalty; unset or any other
    /// value keeps the card's 1.5. Only the 9B reads it. A request's own
    /// `presence_penalty`, the coordinator's registry default included, always
    /// wins, so while the registry sets one the switch does not reach routed
    /// traffic.
    static let qwen35NineBPenaltyEnvironmentKey = "DARKBLOOM_QWEN35_9B_PRESENCE_PENALTY"

    static func qwen35NineBKeepsCardPenalty(environment: [String: String]) -> Bool {
        guard let raw = environment[qwen35NineBPenaltyEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty
        else { return true }
        return !["0", "off", "false", "no"].contains(raw)
    }

    static let qwen35CardModelTypes = [
        "Qwen3.5-9B": "qwen3_5",
        "qwen3.5-35b-a3b": "qwen3_5_moe",
        "qwen3.6-35b-a3b-vl-mtp-mxfp8": "qwen3_5_moe",
    ]

    public var isLegacy: Bool { self == .legacy }

    #if canImport(os)
    private static let logger = Logger(
        subsystem: BuildEnvironment.current.logSubsystem, category: "engine_v2")
    #endif

    /// Family gate. Explicit admission per model onboarding; sharing the
    /// `model_type` is not enough (Nano and Lightning share `nemotron_h`).
    static func honorsArtifactDefaults(modelId: String, modelType: String?) -> Bool {
        if Bonsai9BModelPolicy.matches(modelId: modelId, modelType: modelType) || modelType == "flint" {
            return true
        }
        switch modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "nemotron_h": return EngineV2SupportedModels.isNemotron35ListingModelID(modelId)
        case "glm5_next": return GLM5NextCoordinatorServing.isManagedModelID(modelId)
        default: return false
        }
    }

    /// Resolve once at slot construction. `.legacy` when the gate is off,
    /// the checkpoint directory is unknown, the file is absent or
    /// unreadable, or the artifact declares `do_sample: false`. `environment`
    /// is read for `DARKBLOOM_QWEN35_9B_PRESENCE_PENALTY` alone.
    static func resolve(
        modelId: String, modelType: String?, modelDirectory: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> EngineV2SamplingDefaults {
        if let type = qwen35CardModelTypes[modelId], type == modelType {
            if modelId == qwen35NineBModelID, !qwen35NineBKeepsCardPenalty(environment: environment) {
                return qwen35NineBNoPenaltyDefaults
            }
            return qwen35CardDefaults
        }
        if MuseGlimmerModelPolicy.matches(modelId: modelId, modelType: modelType) {
            return museGlimmerCardDefaults
        }
        guard honorsArtifactDefaults(modelId: modelId, modelType: modelType),
            let modelDirectory
        else { return .legacy }
        let url = modelDirectory.appendingPathComponent("generation_config.json")
        guard let data = try? Data(contentsOf: url) else { return .legacy }
        let defaults = parse(data)
        #if canImport(os)
        if !defaults.isLegacy {
            // Values only — never request content.
            let temperature = defaults.temperature.map { String($0) } ?? "legacy"
            let topP = defaults.topP.map { String($0) } ?? "legacy"
            let topK = defaults.topK.map { String($0) } ?? "legacy"
            let penalty = defaults.repetitionPenalty.map { String($0) } ?? "legacy"
            Self.logger.info(
                "engine_v2: sampling defaults from generation_config model_id=\(modelId, privacy: .public) temperature=\(temperature, privacy: .public) top_p=\(topP, privacy: .public) top_k=\(topK, privacy: .public) repetition_penalty=\(penalty, privacy: .public)"
            )
        }
        #endif
        return defaults
    }

    /// Pure parse of a `generation_config.json` body. Out-of-range or
    /// non-finite values are ignored field-by-field (never guessed).
    static func parse(_ data: Data) -> EngineV2SamplingDefaults {
        guard let file = try? JSONDecoder.json5().decode(File.self, from: data) else {
            return .legacy
        }
        if file.do_sample == false { return .legacy }
        var defaults = EngineV2SamplingDefaults()
        if let temperature = file.temperature, temperature.isFinite, temperature >= 0 {
            defaults.temperature = temperature
        }
        if let topP = file.top_p, topP.isFinite, topP > 0, topP <= 1 {
            defaults.topP = topP
        }
        if let topK = file.top_k, topK >= 0 {
            defaults.topK = topK
        }
        if let penalty = file.repetition_penalty, penalty.isFinite, penalty > 0 {
            defaults.repetitionPenalty = penalty
        }
        return defaults
    }

    private struct File: Decodable {
        var do_sample: Bool?
        var temperature: Float?
        var top_p: Float?
        var top_k: Int?
        var repetition_penalty: Float?
    }
}
