import Foundation
import MLX
import MLXLMCommon
@_spi(Benchmarking) @testable import ProviderCore
import ProviderCoreFoundation

/// Test-only access to the ordinary managed MiMo slot construction. The
/// public offline benchmark intentionally fences prefix participation; this
/// fixture does not change that gate or manufacture a native capability.
enum NativeHistoricalPrefixArchitecture {
  static func load(
    modelID: String, directory: URL, verifiedWeightHash: String,
    environment: [String: String], mtpEnabled: Bool = false, kvBackend: String = "auto"
  ) async throws
    -> (container: ModelContainer, session: EngineV2BenchmarkSession)
  {
    guard let load = try MiMoV26ServingLoad.inspect(directory: directory),
      PrefixCachePolicy.checkpointIdentityHash(verifiedWeightHash) != nil,
      PrefixCachePolicy.isEnabled(modelId: modelID, environment: environment),
      !PrefixCachePolicy.isMemoryEnabled(environment: environment),
      ["auto", "contiguous", "paged"].contains(kvBackend),
      kvBackend != "paged" || environment["DARKBLOOM_MIMO_NATIVE_PAGED_TARGET"] == "1"
    else { throw MiMoV26ServingLoadError.nativeOwnerMismatch }
    let operatorReserve = ProviderSettings(name: "benchmark").memoryReserveGB * (1 << 30)
    let reserve = UnifiedMemoryCap.resolvedActivationReserveBytes(
      env: environment, modelIDs: [modelID])
    let budget = GlobalKVCacheBudget(
      capFraction: UnifiedMemoryCap.resolvedCapFraction(explicit: nil, env: environment),
      activationReserveBytes: reserve, configReserveBytes: operatorReserve)
    let registry = MiMoV26NativeLoadRegistry.shared
    try registry.requireNewNativeWorkAllowed()
    let lifecycle = try registry.openLifecycle()
    do {
      try load.claim(budget: budget, lifecycle: lifecycle, registry: registry)
      guard let transaction = load.transaction else {
        throw MiMoV26ServingLoadError.nativeOwnerMismatch
      }
      let ownership = MiMoV26BenchmarkOwnership(
        registry: registry, lifecycle: lifecycle, transaction: transaction)
      let task = try registry.launchOwnedTask(for: transaction) {
        _ = try GPUEnforcement.requireMetal()
        MLXMemoryGuard.configureOnce()
        let serving = try await ModelContainerLoading.loadServingContainer(
          from: directory, modelID: modelID, nativeMiMoLoad: load)
        guard let container = serving.autoregressive else {
          throw MiMoV26ServingLoadError.nativeOwnerMismatch
        }
        guard
          WeightHasher.computeHash(snapshotDir: directory, modelID: modelID) == verifiedWeightHash
        else {
          throw EngineV2BenchmarkSession.Failure.invalidVerifiedWeightHash
        }
        try load.recheck()
        let tokenizer = await container.perform { TokenizerHandle($0.tokenizer) }
        let session = try await transaction.performSetup {
          try await assemble(
            modelID: modelID, directory: directory,
            verifiedWeightHash: verifiedWeightHash, environment: environment,
            load: load, serving: serving, tokenizer: tokenizer,
            budget: budget, reserve: reserve, operatorReserve: operatorReserve,
            ownership: ownership, mtpEnabled: mtpEnabled, kvBackend: kvBackend)
        }
        _ = try await load.sealConstructionForPublication()
        return try load.commitPublication { (container: container, session: session) }
      }
      return try await withTaskCancellationHandler {
        let result = try await task.value
        await registry.joinOwnedTasksFromOutside(transaction)
        try Task.checkCancellation()
        return result
      } onCancel: {
        task.cancel()
        transaction.revoke()
      }
    } catch {
      _ = try? registry.closeLifecycle(lifecycle)
      load.revoke()
      if let transaction = load.transaction {
        await registry.joinOwnedTasksFromOutside(transaction)
      }
      let retirement = await load.finishFailureAfterUnwind()
      if case .notClaimed = retirement { throw error }
      try EngineV2BenchmarkSession.requireNativeRetirement(retirement)
      throw error
    }
  }

  private static func assemble(
    modelID: String, directory: URL, verifiedWeightHash: String,
    environment: [String: String], load: MiMoV26ServingLoad,
    serving: ProviderModelContainer, tokenizer: TokenizerHandle,
    budget: GlobalKVCacheBudget, reserve: UInt64, operatorReserve: UInt64,
    ownership: MiMoV26BenchmarkOwnership, mtpEnabled: Bool, kvBackend: String
  ) async throws -> EngineV2BenchmarkSession {
    let preparation = try MiMoV26ServingLoad.preparation(
      mode: mtpEnabled ? .on : .off,
      externalPath: nil, environment: environment,
      embeddedArtifactDeclared: load.hasEmbeddedMTP)
    let prepared = try await EngineV2SlotFactory.prepareProductionModel(
      modelId: modelID, isVLM: false, modelDirectory: directory,
      container: serving, specDecPreparation: preparation)
    let sizing = await serving.sizing(modelPath: directory, defaultMaxTokens: 8192)
      .replacingAuxiliaryWeightBytes(prepared.assistantBytes)
    let grant = try EngineV2Factory.benchmarkProductionGrant(
      modelId: modelID, sizing: sizing,
      environment: environment, operatorReserveBytes: operatorReserve)
    let bundle = try await EngineV2SlotFactory.makeProductionBundle(
      modelId: modelID,
      modelType: "mimo_v2", isVLM: false, modelDirectory: directory,
      container: serving, tokenizer: tokenizer, sizing: sizing,
      kvBytesCapacity: grant.grantBytes, maxConcurrentRequests: 1, constructionPurpose: .benchmark,
      kvBudget: budget, activationReserveBytes: reserve, kvBackendConfig: kvBackend,
      weightHash: verifiedWeightHash, specDecPreparation: preparation, preparedModel: prepared,
      environment: environment, startServingTelemetry: false)
    let expectedLayouts = mtpEnabled
      ? [CBv2CompleteCheckpointManifest.pagedAsymmetricMTPLayout,
         CBv2CompleteCheckpointManifest.contiguousAsymmetricMTPLayout]
      : [CBv2CompleteCheckpointManifest.pagedAsymmetricLayout,
         CBv2CompleteCheckpointManifest.contiguousAsymmetricLayout]
    guard let engine = await bundle.bridge.ownedEngine as? EngineV2,
      let store = bundle.bridge.ssdHybridCheckpointStore,
      expectedLayouts.contains(store.config.backendLayout),
      bundle.bridge.prefixCacheModelStatus().state == .ready,
      bundle.bridge.durablePrefixCacheEvidenceSource != nil,
      engine.hybridPrefixCache == nil, bundle.mtpStatus.active == mtpEnabled,
      (engine.mtpMetricsSnapshot()?.active == true) == mtpEnabled,
      engine.nativeCompletionFault == nil
    else { throw EngineV2BenchmarkSession.Failure.unexpectedEngine }
    Memory.clearCache()
    let sample = budget.memoryHeadroomSnapshot()
    let kind = await bundle.bridge.kvBackendKind
    let ceiling = await bundle.bridge.kvBackendPoolBytes()
    guard
      KVHeadroomProbe.postBuildServeable(
        kvBackendKind: kind, pagedPoolBytes: ceiling,
        activationReserveBytes: reserve, measuredHeadroomBytes: sample.runtimeRemainingBytes)
    else {
      throw EngineV2BenchmarkSession.Failure.unservablePostLoad(
        headroomBytes: sample.runtimeRemainingBytes,
        requiredBytes: UnifiedMemoryCap.minimumLoadKVBytes)
    }
    let maximumKV = UnifiedMemoryCap.kvBudgetBytes(
      physicalBytes: ProcessInfo.processInfo.physicalMemory,
      residentWeightBytes: UInt64(Memory.activeMemory), activationReserveBytes: reserve,
      configReserveBytes: operatorReserve, capFraction: grant.capFraction)
    return EngineV2BenchmarkSession(
      bundle: bundle, engine: engine,
      backend: kind.rawValue, fallback: await bundle.bridge.kvBackendFallbackReason,
      effectiveMaxConcurrentRequests: await bundle.bridge.maxConcurrentRequests,
      memoryEnabled: false,
      activationReserveBytes: reserve, postLoadMaximumKVBytes: maximumKV,
      budget: budget, assistantIdentity: EngineV2Factory.benchmarkAssistantIdentity(preparation.artifact),
      productionGrant: grant,
      postBuildHeadroomBytes: sample.runtimeRemainingBytes, nativeMiMoOwnership: ownership)
  }
}
