import Foundation
import MLX

/// Admission from an actual verified local stage and retained local inputs.
/// It binds no external reference and makes no numerical comparison claim.
struct QwenLayerStageProfiledComputeAdmission {
    let local: QwenRegistered9BLongPrefillReferenceAdmission
    let agreement: QwenLayerStageProfiledPrefillStartAgreement
    let source: QwenLayerStageProfiledComputeSource
    let stageIndex: Int

    init(loaded: LoadedQwenLayerStage, local: QwenRegistered9BLongPrefillReferenceAdmission,
         agreement: QwenLayerStageProfiledPrefillStartAgreement) throws {
        let plan = local.plan, r = loaded.receipt, storage = r.storageCommitment
        guard (0..<2).contains(loaded.stageIndex), plan.stages.count == 2,
              plan.originalConfiguration == local.configuration, plan.layers == 32, plan.interval == 4,
              plan.stages[0].sourceRange == (0..<16), plan.stages[1].sourceRange == (16..<32),
              local.request.request.profile == .longPrefill8KV1,
              local.request.request.promptCount == 8192, local.request.request.chunkSize == 512,
              local.request.request.outputCount == 1, local.request.request.batchSize == 1,
              local.request.request.maximumTokens == 8193, local.request.steps.count == 16,
              local.request.vocabularySize == 248_320, local.request.teacherTokenIDs.isEmpty,
              loaded.plan.fingerprint == plan.fingerprint, loaded.vocabularySize == local.request.vocabularySize,
              loaded.layerCount == 16, loaded.activationDType == .bfloat16,
              r.schemaVersion == 1, r.stageIndex == loaded.stageIndex,
              r.verifiedAggregateSHA256 == local.resource.expectedArtifactAggregateSHA256,
              r.sourceConfigurationSHA256 == local.resource.sourceConfigurationSHA256,
              r.sourceConfigurationSHA256 == sha256(local.configuration), r.planSHA256 == plan.fingerprint,
              r.bf16ConversionEnabled, r.embeddingActivationDType == "bfloat16",
              qwenStageWireIsSHA256(r.sourceParameterLayoutSHA256),
              r.sourceModelTensorBytes > 0, r.sourceModelTensorBytes <= LocalCorrectnessStorage.maximumSourceModelTensorBytes,
              r.largestHostTensorBytes > 0, r.largestHostTensorBytes <= LocalCorrectnessStorage.maximumHostTensorBytes,
              storage.schemaVersion == 1, storage.stages.map(\.stageIndex) == [0, 1],
              storage.verifiedAggregateSHA256 == r.verifiedAggregateSHA256,
              storage.sourceConfigurationSHA256 == r.sourceConfigurationSHA256,
              storage.planSHA256 == r.planSHA256, storage.bf16ConversionEnabled,
              storage.sourceModelTensorBytes == r.sourceModelTensorBytes,
              storage.sourceTensorManifestSHA256 == r.sourceTensorManifestSHA256,
              storage.sourceTensorCount == 927, storage.canonicalTensorCount == 927,
              sha256(try canonicalJSONData(storage)) == r.storageCommitmentSHA256,
              sha256(try canonicalJSONData(local.arithmetic)) == local.arithmeticEnvironmentSHA256 else {
            throw ProbeError("Profiled compute requires the exact registered source, local history, stage and arithmetic admission")
        }
        let index = loaded.stageIndex, stage = plan.stages[index], summary = storage.stages[index]
        guard r.stagePlanSHA256 == stage.fingerprint,
              r.constructionConfigurationSHA256 == sha256(stage.constructionConfiguration),
              loaded.configurationData == stage.constructionConfiguration,
              r.loadedTensorBytes == summary.loadedTensorBytes, r.loadedTensorBytes > 0,
              r.parameterLayoutSHA256 == summary.parameterLayoutSHA256,
              r.activeParameterLayoutSHA256 == summary.activeParameterLayoutSHA256,
              r.activeMappingSHA256 == summary.activeMappingSHA256,
              r.inertTensorBytes == summary.inertTensorBytes,
              r.activeTensors.count == summary.activeTensorCount,
              try QwenLongPrefillCheckedBytes.sum(storage.stages.map(\.loadedTensorBytes)) == r.sourceModelTensorBytes,
              try QwenLongPrefillCheckedBytes.sum(r.activeTensors.map(\.byteCount)) == r.loadedTensorBytes else {
            throw ProbeError("Profiled compute stage storage differs from its verified common commitment")
        }
        for i in 0..<2 {
            guard storage.stages[i].stagePlanSHA256 == plan.stages[i].fingerprint,
                  storage.stages[i].constructionConfigurationSHA256 == sha256(plan.stages[i].constructionConfiguration) else {
                throw ProbeError("Profiled compute storage names a different compact stage")
            }
        }
        let wireSource = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: r.sourceConfigurationSHA256,
            artifactAggregateSHA256: r.verifiedAggregateSHA256, storageCommitmentSHA256: r.storageCommitmentSHA256,
            planFingerprint: plan.fingerprint, producerStageFingerprint: plan.stages[0].fingerprint)
        let expected = try QwenLayerStageProfiledPrefillStartAgreement(epoch: agreement.descriptor.epoch,
            request: local.request, sourceIdentity: wireSource, consumerStageFingerprint: plan.stages[1].fingerprint,
            producerConstructionConfigurationSHA256: sha256(plan.stages[0].constructionConfiguration),
            consumerConstructionConfigurationSHA256: sha256(plan.stages[1].constructionConfiguration),
            bf16ConversionEnabled: true, arithmeticEnvironmentSHA256: local.arithmeticEnvironmentSHA256,
            hiddenSize: local.resource.geometry.hiddenSize, nativeDType: "bfloat16", logitsDType: "bfloat16",
            schedulingPolicy: agreement.descriptor.schedulingPolicy)
        guard expected.fingerprint == agreement.fingerprint else {
            throw ProbeError("Profiled compute v4 agreement differs from independently admitted local source/input/environment")
        }
        self.local = local; self.agreement = agreement; self.stageIndex = index
        source = .init(stageIndex: index, artifactAggregateSHA256: r.verifiedAggregateSHA256,
            sourceConfigurationSHA256: r.sourceConfigurationSHA256,
            sourceParameterLayoutSHA256: r.sourceParameterLayoutSHA256,
            sourceModelTensorBytes: r.sourceModelTensorBytes, loadedTensorBytes: r.loadedTensorBytes,
            planSHA256: plan.fingerprint, storageCommitmentSHA256: r.storageCommitmentSHA256,
            sourceLoadReceiptSHA256: sha256(try canonicalJSONData(r)),
            arithmeticEnvironmentSHA256: local.arithmeticEnvironmentSHA256,
            promptFileSHA256: local.promptFileSHA256, promptTokenIDsSHA256: local.promptTokenIDsSHA256,
            bf16ConversionEnabled: true, embeddingActivationDType: "bfloat16")
    }
}
