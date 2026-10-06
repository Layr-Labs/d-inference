import Foundation
import MLXLMCommon
import MLXVLM

/// Explicit serving ownership. Native diffusion is not represented by a dummy
/// autoregressive model; callers must choose the appropriate execution path.
enum ProviderModelContainer: Sendable {
    case autoregressive(ModelContainer)
    case nativeMiMo(ModelContainer, MiMoV26ServingLoad)
    case diffusion(DiffusionGemmaContainer)

    var autoregressive: ModelContainer? {
        switch self {
        case .autoregressive(let value), .nativeMiMo(let value, _): value
        case .diffusion: nil
        }
    }
    var diffusion: DiffusionGemmaContainer? {
        if case .diffusion(let value) = self { value } else { nil }
    }
    var identity: ObjectIdentifier {
        switch self {
        case .autoregressive(let value): ObjectIdentifier(value)
        case .nativeMiMo(let value, _): ObjectIdentifier(value)
        case .diffusion(let value): ObjectIdentifier(value)
        }
    }

    func tokenizerHandle(modelType: String?, directory: URL) async -> TokenizerHandle {
        switch self {
        case .autoregressive(let value):
            return await value.perform { context in
                TokenizerHandle(context.tokenizer, toolConstraintContractVerified:
                    Gemma4ToolConstraintContract.isVerified(modelType: modelType, modelDirectory: directory))
            }
        case .diffusion(let value):
            return await value.perform { TokenizerHandle($0.tokenizer) }
        case .nativeMiMo(let value, _):
            return await value.perform { TokenizerHandle($0.tokenizer) }
        }
    }

    func sizing(modelPath: URL?, defaultMaxTokens: Int) async -> SlotSizingSnapshot {
        switch self {
        case .autoregressive(let value):
            return await SlotSizingSnapshot.build(container: value, modelPath: modelPath,
                                                   fallbackDefaultMaxTokens: defaultMaxTokens)
        case .nativeMiMo(let value, let load):
            // Strict serial receipt covers the complete immutable parameter
            // closure. Embedded MTP/media are already included, not auxiliaries.
            let config = load.plan.bundlePlan.configuration
            let full = config.hybridLayerPattern.filter { $0 == 0 }.count
            let geometry = config.fullAttention
            let rate = full * (geometry.headDim + geometry.valueHeadDim) * geometry.keyValueHeads * 2
            return await value.perform { context in
                let actualBytes = context.model.parameters().flattened().reduce(0) { sum, item in
                    let next = sum.addingReportingOverflow(item.1.nbytes)
                    return next.overflow ? Int.max : next.partialValue
                }
                return SlotSizingSnapshot(weightsBytes: actualBytes,
                    fp16KVBytesPerToken: rate, maxContextLength: config.maxPositionEmbeddings,
                    defaultMaxTokens: min(config.maxPositionEmbeddings, defaultMaxTokens))
            }
        case .diffusion(let value):
            return await value.perform { context in
                let config = context.model.configuration.textConfig
                let full = config.layerTypes.filter { $0 == "full_attention" }.count
                let rate = full * 2 * (config.globalKeyValueHeads ?? config.keyValueHeads)
                    * config.globalHeadDimension * 2
                return SlotSizingSnapshot(
                    weightsBytes: context.model.parameters().flattened().reduce(0) { $0 + $1.1.nbytes },
                    fp16KVBytesPerToken: rate, maxContextLength: config.maxPositionEmbeddings,
                    defaultMaxTokens: context.generationConfiguration.maxNewTokens)
            }
        }
    }

    func releaseExternalResources() async {
        if let autoregressive { await ModelContainerLoading.releaseExternalResources(in: autoregressive) }
        // Native diffusion has no external mmap lease. Its engine must drain
        // before this container is dropped by the slot/newcomer owner.
    }
}
