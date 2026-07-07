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
//   * `gemma4…`      — Gemma 4 text (`gemma4_text`) AND the Gemma 4 VLM
//                      wrapper (`gemma4`, served via the weight-sharing
//                      text-model extraction + vision prefill)
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
    /// Whether the v2 engine can serve this `model_type` (config.json).
    /// nil/unknown types are unsupported — fail closed.
    public static func isSupported(modelType: String?) -> Bool {
        guard let raw = modelType?.trimmingCharacters(in: .whitespaces).lowercased(),
            !raw.isEmpty
        else { return false }
        if raw == "gpt_oss" { return true }
        // Gemma 4 family: `gemma4` (VLM wrapper), `gemma4_text`, and any
        // future gemma4-suffixed text/VLM variant. Deliberately a prefix so
        // `gemma3`/`gemma2` (no CBv2 adapter) can never match.
        if raw.hasPrefix("gemma4") { return true }
        return false
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
}
