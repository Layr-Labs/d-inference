// Copyright © 2026 Eigen Labs.
//
// Architecture-derived supported set for the v2 engine (v0.7.5 fail-loud).
//
// v0.7.5 serves EVERYTHING through ContinuousBatchingV2 — there is no
// legacy fallback — so a model is advertised to the coordinator ONLY when
// its family has a CBv2 adapter. This predicate is the scan/advertise-time
// mirror of the `EngineV2Factory.makeProductionEngine` switch (Gemma4Text +
// GPT-OSS module families), keyed on the `model_type` string config.json
// declares (the value `ModelScanner.parseModelInfo` stamps on `ModelInfo`):
//
//   * `gpt_oss`      — GPT-OSS (GPTOSSModel)
//   * `gemma4`       — Gemma 4 VLM wrapper, serving through its directly
//                      owned text tower plus vision prefill
//   * `gemma4_text`  — Gemma 4 text target
//
// Everything else (gemma3, qwen*, llama, …) has no CBv2 adapter: it is
// dropped from the advertised set at startup and at prefetch-verify time
// (WARN log), so the coordinator never routes to it. A load request for an
// unsupported id (stale catalog) then fails the advertised-set guard in
// `ensureModelLoaded` → 404 via `loadErrorStatusCode`, never a silent
// degrade. Any change to the `makeProductionEngine` switch MUST be
// reflected here.

import Foundation

public enum EngineV2SupportedModels {
    /// Exact config namespaces registered by the official Gemma 4 target
    /// factories. Keep this closed: assistant checkpoints intentionally share
    /// the `gemma4` prefix and must never become advertised chat targets.
    private static let gemma4TargetTypes: Set<String> = ["gemma4", "gemma4_text"]

    static func isGemma4Target(modelType: String?) -> Bool {
        guard let raw = normalized(modelType) else { return false }
        return gemma4TargetTypes.contains(raw)
    }

    /// Whether the v2 engine can serve this `model_type` (config.json).
    /// nil/unknown types are unsupported — fail closed.
    public static func isSupported(modelType: String?) -> Bool {
        guard let raw = normalized(modelType) else { return false }
        if raw == "gpt_oss" { return true }
        return gemma4TargetTypes.contains(raw)
    }

    /// Split an advertised-model list into (supported, unsupported) by the
    /// predicate above. Order-preserving; pure, for scan-time gating + tests.
    public static func partition(
        _ models: [ModelInfo]
    ) -> (supported: [ModelInfo], unsupported: [ModelInfo]) {
        var supported: [ModelInfo] = []
        var unsupported: [ModelInfo] = []
        for model in models {
            if isSupported(modelType: model.modelType) {
                supported.append(model)
            } else {
                unsupported.append(model)
            }
        }
        return (supported, unsupported)
    }

    private static func normalized(_ modelType: String?) -> String? {
        guard let raw = modelType?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !raw.isEmpty
        else { return nil }
        return raw
    }
}
