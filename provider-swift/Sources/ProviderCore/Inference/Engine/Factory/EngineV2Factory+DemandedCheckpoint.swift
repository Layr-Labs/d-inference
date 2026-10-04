// Copyright © 2026 Eigen Labs.

import MLXLLM
import MLXLMCommon

extension EngineV2Factory {
  /// Verified aggregate of the canonical Lightning artifact qualified with
  /// active MTP. A replacement build requires its own numerical/cost evidence.
  static let qualifiedNemotron35ShortCheckpointAggregateHash =
    "be622ff6ae88533eb31ce984ddc95e5edc3bc52de1767536f2058151383d891a"

  /// Serving qualifies dense Qwen and measured canonical Lightning/Bonsai
  /// artifacts on their paged store. The benchmark SPI can measure another
  /// recurrent candidate. Historical/native layouts retain their frontier.
  static func demandedShortCheckpointMinimumTokens(
    model: any LanguageModel, backend: EngineV2KVBackendKind,
    store: (any CBv2CompletePrefixCache)?,
    constructionPurpose: ConstructionPurpose = .serving,
    checkpointPartition: EngineV2BenchmarkCheckpointPartition = .production
  ) -> Int? {
    guard backend == .paged, let store = store as? SSDHybridCheckpointStore,
            store.config.backendLayout == CBv2CompleteCheckpointManifest.pagedLayout
    else { return nil }
    if model is Qwen35Model, !(model is Qwen35MoEModel) {
      return store.config.minEffectiveTokens
    }
    if let lightning = model as? NemotronH35Model,
      store.config.modelId == EngineV2SupportedModels.nemotron35LightningRegistryModelID,
      store.identity.modelAggregateHash == qualifiedNemotron35ShortCheckpointAggregateHash,
      store.config.minEffectiveTokens >= 1_024,
      !lightning.cbv2RecurrentStateSpec.layers.isEmpty
    {
      return store.config.minEffectiveTokens
    }
    if let minimum = qualifiedBonsaiShortCheckpointMinimumTokens(model: model, store: store) {
      return minimum
    }
    let recurrent = model as? any CBv2RecurrentLanguageModelForwardable
    return benchmarkRecurrentShortCheckpointMinimumTokens(
      constructionPurpose: constructionPurpose, checkpointPartition: checkpointPartition,
      backend: backend, backendLayout: store.config.backendLayout,
      minimumTokens: store.config.minEffectiveTokens,
      hasRecurrentState: recurrent?.cbv2RecurrentStateSpec.layers.isEmpty == false)
  }

  /// Host-only policy shared by the actual assembly and qualification tests.
  /// A benchmark request cannot qualify another backend or lower a floor.
  static func benchmarkRecurrentShortCheckpointMinimumTokens(
    constructionPurpose: ConstructionPurpose,
    checkpointPartition: EngineV2BenchmarkCheckpointPartition,
    backend: EngineV2KVBackendKind, backendLayout: String,
    minimumTokens: Int, hasRecurrentState: Bool
  ) -> Int? {
    guard constructionPurpose == .benchmark,
      checkpointPartition == .demandedRecurrentQualification,
      backend == .paged,
      backendLayout == CBv2CompleteCheckpointManifest.pagedLayout,
      minimumTokens >= 1_024, hasRecurrentState
    else { return nil }
    return minimumTokens
  }

  /// The longer-prompt extension is available only to this typed benchmark
  /// construction. Serving keeps its qualified short-only partition policy.
  static func benchmarkDemandedCheckpointPartitionIncludesLongPrompts(
    model: any LanguageModel, backend: EngineV2KVBackendKind,
    store: (any CBv2CompletePrefixCache)?,
    constructionPurpose: ConstructionPurpose,
    checkpointPartition: EngineV2BenchmarkCheckpointPartition
  ) -> Bool {
    guard constructionPurpose == .benchmark,
      checkpointPartition == .demandedRecurrentQualification,
      let store = store as? SSDHybridCheckpointStore,
      let recurrent = model as? any CBv2RecurrentLanguageModelForwardable
    else { return false }
    return benchmarkRecurrentShortCheckpointMinimumTokens(
      constructionPurpose: constructionPurpose, checkpointPartition: checkpointPartition,
      backend: backend, backendLayout: store.config.backendLayout,
      minimumTokens: store.config.minEffectiveTokens,
      hasRecurrentState: !recurrent.cbv2RecurrentStateSpec.layers.isEmpty) != nil
  }
}
