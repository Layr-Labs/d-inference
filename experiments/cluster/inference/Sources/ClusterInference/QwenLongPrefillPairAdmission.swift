import Foundation

/// No external reference parser: the caller supplies the CPU reference returned
/// by the verified full-model producer after releasing that complete model.
func admitQwenLongPrefillPair(reference: QwenLongPrefillReferenceEvidence,
    stages: [LoadedQwenLayerStage], local: QwenRegistered9BLongPrefillReferenceAdmission
) throws -> QwenLayerStageProfiledPrefillStartAgreement {
    let source = reference.execution.source
    guard stages.count == 2, stages.map(\.stageIndex) == [0, 1],
          reference.execution.request.fingerprint == local.request.fingerprint,
          reference.promptFileSHA256 == local.promptFileSHA256,
          reference.promptTokenIDsSHA256 == local.promptTokenIDsSHA256,
          reference.arithmeticEnvironmentSHA256 == local.arithmeticEnvironmentSHA256,
          source.arithmeticEnvironmentSHA256 == local.arithmeticEnvironmentSHA256,
          source.planSHA256 == local.plan.fingerprint,
          source.bf16ConversionEnabled, source.embeddingActivationDType == "bfloat16",
          source.layerCount == 32, source.vocabularySize == 248_320 else {
        throw ProbeError("Long pair baseline differs from locally admitted input/source/geometry")
    }
    for stage in stages {
        let receipt = stage.receipt
        guard receipt.verifiedAggregateSHA256 == source.artifactAggregateSHA256,
              receipt.sourceConfigurationSHA256 == source.sourceConfigurationSHA256,
              receipt.sourceParameterLayoutSHA256 == source.sourceParameterLayoutSHA256,
              receipt.sourceModelTensorBytes == source.sourceModelTensorBytes,
              receipt.storageCommitmentSHA256 == stages[0].receipt.storageCommitmentSHA256 else {
            throw ProbeError("Long pair loaded stage differs from independently verified complete source")
        }
    }
    let receipt = stages[0].receipt
    let wireSource = try QwenLayerStageWireSourceIdentity(
        sourceConfigurationSHA256: receipt.sourceConfigurationSHA256,
        artifactAggregateSHA256: receipt.verifiedAggregateSHA256,
        storageCommitmentSHA256: receipt.storageCommitmentSHA256,
        planFingerprint: local.plan.fingerprint,
        producerStageFingerprint: local.plan.stages[0].fingerprint)
    return try .init(epoch: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
        request: local.request, sourceIdentity: wireSource,
        consumerStageFingerprint: local.plan.stages[1].fingerprint,
        producerConstructionConfigurationSHA256: sha256(local.plan.stages[0].constructionConfiguration),
        consumerConstructionConfigurationSHA256: sha256(local.plan.stages[1].constructionConfiguration),
        bf16ConversionEnabled: true, arithmeticEnvironmentSHA256: local.arithmeticEnvironmentSHA256,
        hiddenSize: 4096, nativeDType: "bfloat16", logitsDType: "bfloat16", schedulingPolicy: .serial)
}
