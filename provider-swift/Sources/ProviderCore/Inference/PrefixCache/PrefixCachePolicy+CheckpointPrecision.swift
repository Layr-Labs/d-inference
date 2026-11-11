// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

extension PrefixCachePolicy {
    /// Whether `modelId`'s checkpoints default to native precision. None yet.
    static func defaultsToNativeCheckpoints(modelId _: String) -> Bool { false }

    /// The precision a slot's complete checkpoints are encoded at: the
    /// process switch, then the operator's per-model setting, then the global
    /// setting, then the purpose's default (`PagedKVQuantizationPolicy.resolve`).
    static func checkpointPrecision(
        modelId: String, modelType: String?, global: String, byModel: [String: String],
        environment: [String: String]
    ) throws -> EngineV2KVQuantizationSelection {
        try EngineV2KVQuantizationPolicy.resolve(
            modelType: modelType, global: global, byModel: byModel, modelID: modelId,
            environment: environment, purpose: .checkpoint)
    }
}
