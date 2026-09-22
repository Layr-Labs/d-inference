import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXVLM

/// Native bridge assembly for an already integrity-checked/admitted container.
/// Loading, fleet memory admission and scanner advertisement remain with the
/// slot lifecycle; this helper does not bypass or perform those operations.
enum DiffusionGemmaProviderBridge {
    struct Prepared: Sendable {
        let bridge: EngineV2Bridge
        let tokenizer: TokenizerHandle
        let sizing: SlotSizingSnapshot
    }

    static func make(
        container: DiffusionGemmaContainer, modelID: String, kvBytesCapacity: Int,
        maxConcurrentRequests: Int = 4, sharedBudget: GlobalKVCacheBudget? = nil,
        prefixCache: DiffusionGemmaResidentPrefixConfiguration? = nil,
        completePrefixCache: SSDHybridCheckpointStore? = nil,
        retainMemoryPrefixes: Bool = true, prefillChunkSize: Int = 512,
        prefixCacheStatus: PrefixCacheModelStatus? = nil, pageBacked: Bool = false
    ) async throws -> Prepared {
        guard !pageBacked || sharedBudget != nil else {
            throw CBv2KVError.backendIneligible(reason: "Native paged serving requires process memory admission")
        }
        return try await container.perform { context in
            let config = context.model.configuration.textConfig
            let embedding = context.model.model.decoder.embedTokens
            let dtype = (embedding as? QuantizedEmbedding)?.scales.dtype ?? embedding.weight.dtype
            let fullLayers = config.layerTypes.filter { $0 == "full_attention" }.count
            let nominalRate = fullLayers * 2 * (config.globalKeyValueHeads ?? config.keyValueHeads)
                * config.globalHeadDimension * 2
            let nativeRate = nominalRate / 2 * dtype.size
            let weights = context.model.parameters().flattened().reduce(0) { $0 + $1.1.nbytes }
            let sizing = SlotSizingSnapshot(
                weightsBytes: weights, fp16KVBytesPerToken: nominalRate,
                maxContextLength: config.maxPositionEmbeddings,
                defaultMaxTokens: context.generationConfiguration.maxNewTokens)
            let pageConfig: PagedKVPoolConfig? = pageBacked ? .init(capacityBytes: kvBytesCapacity,
                dtype: dtype, maxPrefillChunk: max(prefillChunkSize, context.model.configuration.canvasLength),
                nominalMaxSequenceLength: config.maxPositionEmbeddings, segmentSizeBytes: 8 << 20,
                layerDTypes: Array(repeating: dtype, count: config.layerCount)) : nil
            let engine = try context.makeNativeEngine(
                kvBytesCapacity: kvBytesCapacity, maxConcurrentRequests: maxConcurrentRequests,
                prefillChunkSize: prefillChunkSize,
                prefixCache: prefixCache, completePrefixCache: completePrefixCache,
                retainMemoryPrefixes: retainMemoryPrefixes, pagedConfiguration: pageConfig,
                processMemoryOwner: pageBacked ? sharedBudget?.makeEngineMemoryOwner() : nil,
                loopConfig: .init(useLegacyRequestTimeout: EngineV2Factory.legacyRequestTimeoutEnabled()))
            let tokenizer = TokenizerHandle(context.tokenizer)
            let eos = context.generationConfiguration.eosTokenIds
                ?? context.model.configuration.base.eosTokenIds?.values ?? config.eosTokenIds ?? []
            let bridge = EngineV2Bridge(
                engine: engine, modelId: modelID, tokenizer: tokenizer, eosTokenIds: Set(eos),
                defaultMaxTokens: sizing.defaultMaxTokens, maxConcurrentRequests: maxConcurrentRequests,
                // The AR first-token forecast does not model canvas convergence.
                // Absolute deadline checks are unchanged; a native forecast and
                // native phase leases remain required before serving qualification.
                prefillDeadlineProjectionEnabled: false,
                kvBytesPerToken: nativeRate, kvBudget: sharedBudget,
                ssdHybridCheckpointStore: completePrefixCache,
                prefixCacheStatus: prefixCacheStatus,
                kvBackendKind: pageBacked ? .paged : .contiguous, pagedPageSize: pageConfig?.pageSize,
                advertisedContextTokens: config.maxPositionEmbeddings)
            return Prepared(bridge: bridge, tokenizer: tokenizer, sizing: sizing)
        }
    }
}
