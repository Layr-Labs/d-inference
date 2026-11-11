// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

extension PrefixCachePolicy {
    /// Exact artifacts whose complete checkpoints default to native precision:
    /// Gemma 4 26B QAT, GPT-OSS 20B, GLM-5.3-Flash and the Bonsai 2 27B and 9B
    /// listings. Under the provider-wide `balanced` default their older
    /// attention rows (GLM: its latent rows) are stored at 4 bits, so a cache
    /// hit restored approximate state and moved answers off the cold ones;
    /// native restores continue the cold prefill (Gemma bit for bit up to
    /// 32,768 tokens, GLM's text). Other builds and aliases keep the global
    /// setting. Nemotron Super has its own default
    /// (`NemotronSuperLocalPrefixCache.checkpointPrecision`) and Lightning the
    /// SDK's (`PagedKVQuantizationPolicy.nativeCheckpointModelTypes`).
    static func defaultsToNativeCheckpoints(modelId: String) -> Bool {
        switch modelId {
        case "gemma-4-26b-qat-4bit", "gpt-oss-20b":
            return true
        default:
            return GLM5NextCoordinatorServing.isManagedModelID(modelId)
                || EngineV2SupportedModels.isBonsai2ListingModelID(modelId)
                || Bonsai9BModelPolicy.matchesModelID(modelId)
        }
    }

    /// The precision a slot's complete checkpoints are encoded at: the
    /// process switch, then the operator's per-model setting, then the global
    /// setting, then the purpose's default (`PagedKVQuantizationPolicy.resolve`).
    /// For `defaultsToNativeCheckpoints` artifacts native is the per-model
    /// default beneath the operator's own entry, so the global setting, which
    /// a saved provider.toml spells out as `balanced`, does not apply to them.
    static func checkpointPrecision(
        modelId: String, modelType: String?, global: String, byModel: [String: String],
        environment: [String: String]
    ) throws -> EngineV2KVQuantizationSelection {
        let byModel = defaultsToNativeCheckpoints(modelId: modelId)
            ? [modelId: EngineV2KVQuantizationSelection.native.rawValue].merging(byModel) { $1 }
            : byModel
        return try EngineV2KVQuantizationPolicy.resolve(
            modelType: modelType, global: global, byModel: byModel, modelID: modelId,
            environment: environment, purpose: .checkpoint)
    }
}
