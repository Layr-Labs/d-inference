// Copyright © 2026 Eigen Labs.

import MLXLMCommon
import MLXVLM

extension EngineV2Factory {
  /// Only this canonical artifact and final serving wrapper have qualified
  /// short demanded-frontier donor/fork parity and cost with actual MTP off.
  static let qualifiedBonsaiShortCheckpointModelID = "ternary-bonsai-2-27b"
  static let qualifiedBonsaiShortCheckpointAggregateHash =
    "ea1e901e4946c0ba9ad70c78517548808b353db6b3a13e87a8fa20468d81244c"

  /// The caller has already required a paged COMPLETE store. Replacements,
  /// aliases and future MTP-capable wrappers require new qualification.
  static func qualifiedBonsaiShortCheckpointMinimumTokens(
    model: any LanguageModel, store: SSDHybridCheckpointStore
  ) -> Int? {
    guard let bonsai = model as? MLXVLM.PrismHadamardQwen35,
      store.config.modelId == qualifiedBonsaiShortCheckpointModelID,
      store.identity.modelAggregateHash == qualifiedBonsaiShortCheckpointAggregateHash,
      store.config.minEffectiveTokens >= 1_024,
      !bonsai.cbv2RecurrentStateSpec.layers.isEmpty,
      !bonsai.cbv2Capabilities.supportsMTP
    else { return nil }
    return store.config.minEffectiveTokens
  }
}
