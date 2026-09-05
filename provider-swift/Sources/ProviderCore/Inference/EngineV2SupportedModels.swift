// Copyright © 2026 Eigen Labs.
//
// Registry-derived supported set for the v2 engine (Darkbloom runner
// contract §6.2 rule 4).
//
// v0.7.5 serves EVERYTHING through ContinuousBatchingV2 — there is no
// legacy fallback — so a model is advertised to the coordinator ONLY when a
// runner in `MLXRunners` claims its `model_type` (the value
// `ModelScanner.parseModelInfo` stamps on `ModelInfo` from config.json).
// `RunnerRegistry.contains(modelType:)` IS the gate: the hand-kept mirror of
// the engine factory's family switch is gone, so a family cannot be
// advertised without a runner, and a runner cannot be added without
// advertising its family.
//
// The registry claims exactly the `modelTypes` each runner's manifest
// declares, so this file names no family. Everything no runner claims
// (gemma3, llama, plain qwen3, …) is dropped from the advertised set at
// startup and at prefetch-verify time (WARN log), so the coordinator never
// routes to it. A load request for an unsupported id (stale catalog) then
// fails the advertised-set guard in `ensureModelLoaded` → 404 via
// `loadErrorStatusCode`, never a silent degrade.

import Foundation
import MLXRunners

public enum EngineV2SupportedModels {
    /// Exact config namespaces registered by the official Gemma 4 target
    /// factories. Keep this closed: assistant checkpoints intentionally share
    /// the `gemma4` prefix and must never become advertised chat targets.
    ///
    /// NOT an engine-support question — `isSupported` answers that from the
    /// registry. This is the SpecDec funnel's target-namespace test
    /// (`SpecDecArtifactFunnel`), which stays narrower than any runner claim:
    /// the Gemma 4 runner serves the target, and an assistant checkpoint is
    /// an artifact bound to that target, never a chat model.
    private static let gemma4TargetTypes: Set<String> = ["gemma4", "gemma4_text"]

    static func isGemma4Target(modelType: String?) -> Bool {
        guard let raw = normalized(modelType) else { return false }
        return gemma4TargetTypes.contains(raw)
    }

    /// Whether a runner claims this `model_type` (config.json).
    /// nil/unknown types are unsupported — fail closed.
    ///
    /// The registry matches the manifest spelling exactly, so the
    /// operator-facing tolerance (surrounding whitespace, case) is applied
    /// here, before the lookup.
    public static func isSupported(modelType: String?) -> Bool {
        guard let raw = normalized(modelType) else { return false }
        return RunnerRegistry.shared.contains(modelType: raw)
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
