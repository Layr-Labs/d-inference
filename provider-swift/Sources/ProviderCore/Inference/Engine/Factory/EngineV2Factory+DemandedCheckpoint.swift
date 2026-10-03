// Copyright © 2026 Eigen Labs.

import MLXLLM
import MLXLMCommon

extension EngineV2Factory {
  /// Qualify only the dense Qwen recurrent codec on its production paged
  /// store. Other architectures, MoE, native historical paths and resident
  /// cache participation keep their existing prompt geometry.
  static func demandedShortCheckpointMinimumTokens(
    model: any LanguageModel, backend: EngineV2KVBackendKind,
    store: (any CBv2CompletePrefixCache)?
  ) -> Int? {
    guard backend == .paged, model is Qwen35Model, !(model is Qwen35MoEModel),
      let store = store as? SSDHybridCheckpointStore,
            store.config.backendLayout == CBv2CompleteCheckpointManifest.pagedLayout
    else { return nil }
    return store.config.minEffectiveTokens
  }
}
