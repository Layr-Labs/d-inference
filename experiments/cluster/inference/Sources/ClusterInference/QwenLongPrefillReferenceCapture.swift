import Foundation
import MLX
import MLXNN

func admitQwenLongPrefillReferenceSource(loaded: LoadedModel,
    admission: QwenRegistered9BLongPrefillReferenceAdmission
) throws -> (QwenLongPrefillReferenceSource, VerifiedQwenDiagnosticReceipt) {
    guard let receipt = loaded.verifiedDiagnosticLoad, receipt.schemaVersion == 1,
          loaded.family == .qwen35, loaded.feedForwardKind == "dense", loaded.gemmaTrace == nil,
          loaded.partitionPlan == nil, loaded.partitionStorage == nil, loaded.directShardLoad == nil,
          loaded.configurationData == admission.configuration,
          loaded.configHash == admission.resource.sourceConfigurationSHA256,
          receipt.configurationSHA256 == loaded.configHash,
          receipt.verifiedAggregateSHA256 == admission.resource.expectedArtifactAggregateSHA256,
          receipt.parameterLayoutSHA256 == loaded.parameterLayoutSHA256,
          modelParameterLayout(loaded.model) == loaded.parameterLayoutSHA256,
          receipt.bf16ConversionEnabled, loaded.bf16ConversionEnabled,
          loaded.embeddingActivationDType == "bfloat16",
          receipt.loadedTensorBytes == receipt.sourceModelTensorBytes,
          receipt.sourceModelTensorBytes > 0,
          receipt.sourceModelTensorBytes <= LocalCorrectnessStorage.maximumSourceModelTensorBytes,
          receipt.largestHostTensorBytes > 0,
          receipt.largestHostTensorBytes <= LocalCorrectnessStorage.maximumHostTensorBytes,
          receipt.tensorCount == 927, receipt.sourceTensorCount == 927,
          loaded.layerCount == 32, loaded.layerCount == admission.plan.layers,
          loaded.vocabularySize == admission.request.vocabularySize,
          loaded.model.trainableParameters().flattened().isEmpty,
          !loaded.model.namedModules().contains(where: { $0.0 == "mtp" || $0.0.hasSuffix(".mtp") }) else {
        throw ProbeError("Long reference requires the verified complete registered BF16 Qwen source with MTP disabled")
    }
    return (.init(artifactAggregateSHA256: receipt.verifiedAggregateSHA256,
        sourceConfigurationSHA256: loaded.configHash, sourceParameterLayoutSHA256: loaded.parameterLayoutSHA256,
        planSHA256: admission.plan.fingerprint, arithmeticEnvironmentSHA256: admission.arithmeticEnvironmentSHA256,
        bf16ConversionEnabled: loaded.bf16ConversionEnabled, embeddingActivationDType: loaded.embeddingActivationDType,
        sourceModelTensorBytes: receipt.sourceModelTensorBytes, layerCount: loaded.layerCount,
        vocabularySize: loaded.vocabularySize), receipt)
}

/// One native argmax/finite selection and one complete native row copy. Reuse
/// the captured Float values to verify tie policy without a second MLX capture.
func captureQwenLongPrefillReferenceLogits(_ logits: MLXArray,
    admission: QwenRegistered9BLongPrefillReferenceAdmission, check: () throws -> Void
) throws -> (QwenRecordedLogits, QwenLongPrefillReferenceSelection) {
    let request = admission.request
    guard logits.shape == [1, request.vocabularySize], logits.dtype == .bfloat16,
          logits.size == request.vocabularySize, logits.nbytes == request.vocabularySize * 2,
          let final = request.steps.last, final.frame.finalPromptChunk, final.committedTokens == 8192 else {
        throw ProbeError("Long reference selection requires the actual complete BF16 final vocabulary row")
    }
    let selected = argMax(logits), finite = all(isFinite(logits))
    eval(logits, selected, finite); try check()
    guard selected.size == 1, selected.dtype == .uint32, finite.size == 1 else {
        throw ProbeError("Long reference finite argmax returned the wrong native scalar contract")
    }
    let allFinite = finite.item(Bool.self); try check()
    guard allFinite else { throw ProbeError("Long reference target logits contain nonfinite values") }
    let token = selected.item(Int.self); try check()
    let captured = try QwenRecordedLogits(logits, vocabularySize: request.vocabularySize, check: check)
    let values = captured.record.values
    guard (0..<request.vocabularySize).contains(token), let maximum = values.max(), maximum.isFinite,
          let firstMaximum = values.firstIndex(of: maximum), token == firstMaximum else {
        throw ProbeError("Native long-reference argmax differs from its captured finite full row")
    }
    let ties = values.reduce(0) { $0 + ($1 == maximum ? 1 : 0) }
    guard ties > 0 else { throw ProbeError("Long reference maximum lacks a vocabulary owner") }
    return (captured, .init(requestFingerprint: request.request.fingerprint,
        recordedRequestFingerprint: request.fingerprint, frame: final.frame, committedTokens: final.committedTokens,
        vocabularySize: request.vocabularySize, tokenID: token, maximumTieCount: ties, maximumLogit: maximum,
        logitsShape: logits.shape, logitsDType: String(describing: logits.dtype),
        selectionDType: String(describing: selected.dtype)))
}
