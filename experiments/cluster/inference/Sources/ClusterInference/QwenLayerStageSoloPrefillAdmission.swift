import Foundation
import MLXNN

/// Loaded-model identity checks only. The root coordinator must first run the
/// unchanged bounded comparison preflight, including its conservative budget.
func admitQwenLayerStageSoloPrefill(loaded: LoadedModel, plan: QwenLayerStagePlan,
    request: QwenLayerStageRecordedRequest, reference: QwenLayerStageSoloPrefillReference
) throws -> QwenLayerStageSoloPrefillReference.Source {
    try reference.requireRequest(request, plan: plan)
    guard let receipt = loaded.verifiedDiagnosticLoad, receipt.schemaVersion == 1,
          loaded.family == .qwen35, loaded.feedForwardKind == "dense", loaded.gemmaTrace == nil,
          loaded.partitionPlan == nil, loaded.partitionStorage == nil, loaded.directShardLoad == nil,
          loaded.configurationData == plan.originalConfiguration,
          loaded.configHash == sha256(plan.originalConfiguration),
          receipt.configurationSHA256 == loaded.configHash,
          receipt.parameterLayoutSHA256 == loaded.parameterLayoutSHA256,
          modelParameterLayout(loaded.model) == loaded.parameterLayoutSHA256,
          receipt.bf16ConversionEnabled == loaded.bf16ConversionEnabled,
          receipt.loadedTensorBytes == receipt.sourceModelTensorBytes,
          receipt.sourceModelTensorBytes > 0,
          receipt.sourceModelTensorBytes <= LocalCorrectnessStorage.maximumSourceModelTensorBytes,
          receipt.largestHostTensorBytes > 0,
          receipt.largestHostTensorBytes <= LocalCorrectnessStorage.maximumHostTensorBytes,
          loaded.model.trainableParameters().flattened().isEmpty,
          !loaded.model.namedModules().contains(where: { $0.0 == "mtp" || $0.0.hasSuffix(".mtp") }),
          ["float16", "bfloat16", "float32"].contains(loaded.embeddingActivationDType),
          loaded.vocabularySize == request.vocabularySize, loaded.layerCount == plan.layers else {
        throw ProbeError("Solo timing requires the verified complete native dense Qwen source model")
    }
    let source = QwenLayerStageSoloPrefillReference.Source(
        artifactAggregateSHA256: receipt.verifiedAggregateSHA256,
        sourceConfigurationSHA256: loaded.configHash,
        sourceParameterLayoutSHA256: loaded.parameterLayoutSHA256, planSHA256: plan.fingerprint,
        bf16ConversionEnabled: loaded.bf16ConversionEnabled,
        embeddingActivationDType: loaded.embeddingActivationDType,
        sourceModelTensorBytes: receipt.sourceModelTensorBytes,
        layerCount: loaded.layerCount, vocabularySize: loaded.vocabularySize)
    guard source == reference.descriptor.source else {
        throw ProbeError("Solo loaded source differs from the independently pinned baseline reference")
    }
    return source
}
