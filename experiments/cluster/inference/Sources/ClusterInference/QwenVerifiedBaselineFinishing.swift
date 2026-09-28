import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// Shared exact finishing of an already verified full model. The caller owns
/// the model and the surrounding error/resource scope; this is not a loader.
func finishVerifiedQwenLayerStageBaseline(model: any LanguageModel,
    originalConfiguration: Data, receipt: VerifiedQwenDiagnosticReceipt,
    expectedAggregateSHA256: String, label: String, layers: Int, hidden: Int,
    vocabulary: Int, namespace: String, check: () throws -> Void
) throws -> LoadedModel {
    // Full-width layer stages impose no two-way TP divisibility condition.
    let scaleTypes = try validatedQwenFeedForwardScaleTypes(model, layers: layers,
        isMoE: false, requireTwoWaySplit: false)
    let embeddingPath = namespace + "model.embed_tokens"
    guard let embedding = model.namedModules().first(where: { $0.0 == embeddingPath })?.1 as? Embedding else {
        throw ProbeError("Verified layer-stage baseline lacks its actual source embedding")
    }
    // This is the real embedding, not the receiving stage's dtype-only
    // placeholder. Check actual arithmetic once, then discard the probe.
    let activationDType = try autoreleasepool { () throws -> DType in
        let activation = embedding(MLXArray([Int32(0)]).reshaped([1, 1]))
        eval(activation)
        try check()
        guard [.float16, .bfloat16, .float32].contains(activation.dtype),
              activation.shape == [1, 1, hidden] else {
            throw ProbeError("Verified baseline embedding activation geometry or dtype differs")
        }
        return activation.dtype
    }
    let layout = modelParameterLayout(model)
    guard receipt.verifiedAggregateSHA256 == expectedAggregateSHA256,
          receipt.configurationSHA256 == sha256(originalConfiguration),
          receipt.parameterLayoutSHA256 == layout,
          receipt.loadedTensorBytes == receipt.sourceModelTensorBytes,
          model.trainableParameters().flattened().isEmpty else {
        throw ProbeError("Verified baseline receipt, source storage or frozen layout differs")
    }
    let loaded = LoadedModel(family: .qwen35, model: model,
        label: label, configHash: receipt.configurationSHA256,
        vocabularySize: vocabulary, layerCount: layers, feedForwardKind: "dense",
        embeddingActivationDType: String(describing: activationDType), ffnScaleDTypes: scaleTypes,
        parameterLayoutSHA256: layout, bf16ConversionEnabled: receipt.bf16ConversionEnabled,
        directShardLoad: nil, configurationData: originalConfiguration,
        partitionPlan: nil, partitionStorage: nil, verifiedDiagnosticLoad: receipt)
    // Empty-cache metadata only. Actual request-context admission and state
    // allocation remain in CBv2RequestSession, after its workload is known.
    let geometry = try CBv2RequestGeometry(loaded: loaded, maximumTokens: 1)
    guard geometry.kvDType == activationDType,
          geometry.recurrent.layers.allSatisfy({ $0.convDType == activationDType }) else {
        throw ProbeError("Actual baseline embedding dtype disagrees with CBv2 KV/conv metadata")
    }
    try check()
    return loaded
}
