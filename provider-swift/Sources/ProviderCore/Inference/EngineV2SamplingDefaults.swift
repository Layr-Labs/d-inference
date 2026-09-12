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
// do_sample true`, and its reasoning-off tool selection at greedy is a
// deterministic refusal on prompts that call the tool under the declared
// sampling on every other host.
//
// Rules:
// * Applied ONLY to fields the request omits. Explicit request values
//   always win (`temperature: 0` still means greedy).
// * `seed`, `logit_bias`, the frequency/presence penalties and `max_tokens`
//   are untouched.
// * Gated per model family with explicit admission, like
//   `ToolChoiceEnforcementPolicy.nativeStructuredTarget`: today only the
//   qualified Nemotron 3.5 Lightning listing honors its artifact defaults.
//   Every other model keeps the legacy defaults byte-for-byte.
// * `do_sample: false` in the file means greedy (legacy), matching HF
//   semantics; an absent or unreadable file is legacy.
// * Resolved once at slot construction (like the stop-token set). The
//   sampler is not part of prompt or cache identity, so prefix-cache and
//   SSD checkpoint identity are unchanged.

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

    public init(
        temperature: Float? = nil, topP: Float? = nil, topK: Int? = nil,
        repetitionPenalty: Float? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repetitionPenalty = repetitionPenalty
    }

    /// Legacy behavior: every omitted knob collapses to the contract's no-op
    /// value (temperature `0.0` = greedy, topP `1.0`, topK `0`,
    /// repetitionPenalty `1.0`) — exactly what `samplingParams(from:)`
    /// produced before artifact defaults existed.
    public static let legacy = EngineV2SamplingDefaults()

    public var isLegacy: Bool { self == .legacy }

    #if canImport(os)
    private static let logger = Logger(
        subsystem: "com.darkbloom.provider", category: "engine_v2")
    #endif

    /// Family gate. Explicit admission per model onboarding; sharing the
    /// `model_type` is not enough (Nano and Lightning share `nemotron_h`).
    static func honorsArtifactDefaults(modelId: String, modelType: String?) -> Bool {
        modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "nemotron_h"
            && EngineV2SupportedModels.isNemotron35ListingModelID(modelId)
    }

    /// Resolve once at slot construction. `.legacy` when the gate is off,
    /// the checkpoint directory is unknown, the file is absent or
    /// unreadable, or the artifact declares `do_sample: false`.
    static func resolve(
        modelId: String, modelType: String?, modelDirectory: URL?
    ) -> EngineV2SamplingDefaults {
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
