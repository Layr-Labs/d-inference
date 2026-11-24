// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon

extension EngineV2Factory {
    /// The private engines of Inkling 2's per-depth load warm-up
    /// (`Inkling2DepthWarmup`), built like the serving engine
    /// (`assembleProductionBuild`: the same model adapter, cache bank, sampler
    /// and admission) on a scratch paged pool with the serving pool's geometry
    /// (page size, types) and a small grant, at the serving segment size or a
    /// small one (`Inkling2DepthWarmup.smallSegmentBytes`), the prefix cache off and no prefix,
    /// checkpoint or SSD store. Depth 0 runs without the drafter; depth k runs
    /// the served drafter at its fixed-depth profile. Nil when the serving
    /// slot is not on a segmented paged pool.
    static func inkling2DepthWarmup(
        model: any LanguageModel,
        tokenizer: any MLXLMCommon.Tokenizer,
        servedBackend: ProductionBackendPreparation,
        drafter: (any CBv2MTPDrafter)?,
        servedRows: Int,
        kvBudget: GlobalKVCacheBudget?,
        grantBytes: Int = Inkling2DepthWarmup.scratchGrantBytes
    ) -> Inkling2DepthWarmup.Runner? {
        guard servedBackend.kind == .paged, var poolConfig = servedBackend.pagedPoolConfig,
            poolConfig.segmentSizeBytes != nil, ProductionModelAdapter(model: model) != nil
        else { return nil }
        poolConfig.capacityBytes = grantBytes
        poolConfig.retainedFreeSegmentBytes = 0
        let drafter = drafter as? Inkling2DSparkDrafter
        let resources = WarmupResources(
            model: model, tokenizer: tokenizer, drafter: drafter, layerKinds: servedBackend.layerKinds,
            capabilities: servedBackend.modelCapabilities, scheduler: servedBackend.schedulerConfig,
            nativeLayerDTypes: servedBackend.nativeLayerDTypes, poolConfig: poolConfig)
        let speculativeRows = Inkling2DSparkDrafter.defaultMTPConfig().maxSpeculativeBatch
        return Inkling2DepthWarmup.Runner(
            makeEngine: { depth, rows, smallSegments in
                let layerKinds = resources.layerKinds
                var config = resources.poolConfig
                if smallSegments { config.segmentSizeBytes = Inkling2DepthWarmup.smallSegmentBytes }
                let backend = try PagedKVBackend(layerKinds: layerKinds, config: config)
                let pagedCaches = backend.makeLayerCaches()
                var storageForModelIndex: [Int: Int] = [:]
                for (storage, kind) in layerKinds.enumerated() {
                    storageForModelIndex[kind.modelLayerIndex ?? storage] = storage
                }
                guard let adapter = ProductionModelAdapter(model: resources.model) else {
                    throw CBv2KVError.backendIneligible(reason: "Inkling 2 warm-up: no model adapter")
                }
                let caches = try adapter.newCaches { index, _ in
                    guard let storage = storageForModelIndex[index], storage < pagedCaches.count else {
                        preconditionFailure("Inkling 2 warm-up: paged storage missing model layer \(index)")
                    }
                    return pagedCaches[storage]
                }
                var scheduler = resources.scheduler
                scheduler.maxConcurrentRequests = max(1, rows)
                scheduler.enablePrefixCache = false
                let prepared = ProductionBackendPreparation(
                    model: resources.model, maxConcurrentRequests: max(1, rows), layerKinds: layerKinds,
                    modelCapabilities: resources.capabilities, backend: backend, caches: caches, kind: .paged,
                    fallbackReason: nil, schedulerConfig: scheduler, pagedPoolDType: nil,
                    nativeLayerDTypes: resources.nativeLayerDTypes)
                let drafting = depth > 0 ? resources.drafter : nil
                return try assembleProductionBuild(
                    model: resources.model, tokenizer: resources.tokenizer, prefixCache: nil,
                    maxConcurrentRequests: max(1, rows), mtpDrafter: drafting,
                    mtpConfig: drafting == nil ? CBv2MTPConfig()
                        : Inkling2DSparkDrafter.defaultMTPConfig(maxDraftTokens: depth, adaptive: false),
                    preparedBackend: prepared).engine
            },
            servedRows: max(1, servedRows),
            speculativeRows: speculativeRows,
            drafterAvailable: drafter != nil,
            memoryPermits: {
                // Room for the scratch pool beside the serving grant: the
                // system must have twice the grant available.
                guard let kvBudget else { return true }
                return kvBudget.memoryHeadroomSnapshot().systemAvailableBytes >= UInt64(grantBytes) * 2
            })
    }

    /// The loaded model, tokenizer and drafter the warm-up engines share with
    /// the serving engine. Each warm-up engine runs alone, before the slot
    /// admits traffic, so the serving engine is idle while they step.
    private struct WarmupResources: @unchecked Sendable {
        let model: any LanguageModel
        let tokenizer: any MLXLMCommon.Tokenizer
        let drafter: Inkling2DSparkDrafter?
        let layerKinds: [CBv2LayerKind]
        let capabilities: CBv2ModelCapabilities
        let scheduler: CBv2SchedulerConfig
        let nativeLayerDTypes: [DType]
        let poolConfig: PagedKVPoolConfig
    }
}
