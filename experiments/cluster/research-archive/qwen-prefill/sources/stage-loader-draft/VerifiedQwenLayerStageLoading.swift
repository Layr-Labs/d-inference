import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Draft verified, full-width layer loading. No ordinary full-model loader or
/// eval(model) call is used. The returned compact model is for the guarded stage
/// session only; it is not a token-to-logit replacement for the complete model.
func loadVerifiedQwenLayerStage(directory: URL, originalConfiguration: Data,
    plan: QwenLayerStagePlan, stageIndex: Int, expectedAggregateSHA256: String
) throws -> LoadedQwenLayerStage {
    guard (0..<2).contains(stageIndex), plan.stages.count == 2,
          plan.stages.enumerated().allSatisfy({ $0.offset == $0.element.index }) else {
        throw ProbeError("Layer-stage index must select one of the two ordered stages")
    }
    return try MLX.withError { error in
        let source = try prepareVerifiedQwenLayerSource(directory: directory,
            originalConfiguration: originalConfiguration, plan: plan,
            expectedAggregateSHA256: expectedAggregateSHA256, check: { try error.check() })
        let other = try inspectOtherQwenLayerStage(source: source,
            stage: plan.stages[1 - stageIndex], check: { try error.check() })
        let prepared = try prepareQwenLayerStageModel(source: source,
            stage: plan.stages[stageIndex], check: { try error.check() })
        let model = prepared.model, inventory = prepared.inventory
        let inventories = [inventory, other].sorted { $0.summary.stageIndex < $1.summary.stageIndex }
        let coverage = inventories.flatMap(\.active)
        guard coverage.count == source.tensors.count,
              Set(coverage.map(\.sourceName)) == Set(source.tensors.map(\.sourceName)),
              coverage.reduce(0, { $0 + $1.byteCount }) == source.sourceBytes else {
            throw ProbeError("Layer-stage inventories do not exactly conserve canonical source storage")
        }
        let commitment = QwenLayerStageStorageCommitment(schemaVersion: 1,
            verifiedAggregateSHA256: source.prepared.checkpoint.aggregate,
            sourceConfigurationSHA256: sha256(originalConfiguration), planSHA256: plan.fingerprint,
            sourceTensorManifestSHA256: source.sourceTensorManifestSHA256,
            sourceModelTensorBytes: source.sourceBytes,
            largestSourceTensorBytes: source.largestSourceBytes,
            sourceTensorCount: source.prepared.sourceTensorCount,
            canonicalTensorCount: source.tensors.count,
            bf16ConversionEnabled: source.bf16ConversionEnabled,
            stages: inventories.map(\.summary))
        // All source/stage geometry, policies, inventory ownership and caps
        // have now passed. This is the first checkpoint tensor materialization.
        try source.prepared.checkpoint.checkUnchanged()
        var loadedBytes = 0, largestHostBytes = 0
        for entry in inventory.active {
            try autoreleasepool {
                guard let tensor = source.prepared.canonical[entry.sourceName] else {
                    throw ProbeError("Verified stage descriptor disappeared")
                }
                let read = try tensor.read(.all)
                let sanitized = model.sanitize(weights: [entry.localName: read.array])
                guard sanitized.count == 1, var array = sanitized[entry.localName],
                      array.shape == entry.shape,
                      String(describing: array.dtype) == entry.sourceDType else {
                    throw ProbeError("Stage sanitizer changed a canonical tensor: \(entry.localName)")
                }
                if source.bf16ConversionEnabled && array.dtype == .float16 {
                    array = array.asType(.bfloat16)
                }
                eval(array)
                try error.check()
                guard array.nbytes == entry.byteCount, read.copiedBytes == entry.byteCount,
                      String(describing: array.dtype) == entry.loadedDType,
                      let buffer = try array.evaluatedBufferInfo(), buffer.isUnique,
                      buffer.dataOffset == 0, buffer.isRowContiguous, buffer.dataElements == array.size,
                      buffer.allocatedBytes >= array.nbytes,
                      buffer.allocatedBytes <= (try Memory.allocationFootprintUpperBound(byteCount: array.nbytes)) else {
                    throw ProbeError("Stage tensor is not an exact, independently owned compact allocation")
                }
                try model.update(parameters: ModuleParameters.unflattened([entry.localName: array]),
                    verify: [.noUnusedKeys, .shapeMismatch])
                try error.check()
                loadedBytes += read.copiedBytes
                largestHostBytes = max(largestHostBytes, read.largestHostTensorBytes)
            }
        }
        model.freeze()
        try error.check()
        // Freeze and parameter introspection do not evaluate unused placeholders
        // or constructor defaults. Each active parameter was evaluated above.
        let actual = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
        let activeLayout = try inventory.active.map { entry -> String in
            guard let value = actual[entry.localName], value.shape == entry.shape,
                  String(describing: value.dtype) == entry.loadedDType else {
                throw ProbeError("Stage's resident active tensor layout differs")
            }
            return "\(entry.localName):\(value.dtype):\(value.shape)"
        }
        guard loadedBytes == inventory.summary.loadedTensorBytes,
              largestHostBytes == (inventory.active.map(\.byteCount).max() ?? 0),
              modelParameterLayout(model) == inventory.summary.parameterLayoutSHA256,
              qwenStageLayout(activeLayout) == inventory.summary.activeParameterLayoutSHA256,
              let kvTypes = (model as? any CBv2CompleteCheckpointKVTypeProviding)?.cbv2CompleteCheckpointKVDTypes,
              !kvTypes.isEmpty, kvTypes.allSatisfy({ $0 == source.activationDType }) else {
            throw ProbeError("Resident stage storage/layout or metadata activation dtype differs")
        }
        try source.prepared.checkpoint.checkUnchanged()
        let summary = inventory.summary
        let receipt = QwenLayerStageLoadReceipt(schemaVersion: 1, stageIndex: stageIndex,
            verifiedAggregateSHA256: commitment.verifiedAggregateSHA256,
            sourceConfigurationSHA256: commitment.sourceConfigurationSHA256,
            constructionConfigurationSHA256: summary.constructionConfigurationSHA256,
            planSHA256: plan.fingerprint, stagePlanSHA256: summary.stagePlanSHA256,
            sourceTensorManifestSHA256: source.sourceTensorManifestSHA256,
            sourceParameterLayoutSHA256: source.sourceParameterLayoutSHA256,
            parameterLayoutSHA256: summary.parameterLayoutSHA256,
            activeParameterLayoutSHA256: summary.activeParameterLayoutSHA256,
            activeMappingSHA256: summary.activeMappingSHA256,
            embeddingActivationDType: String(describing: source.activationDType),
            bf16ConversionEnabled: source.bf16ConversionEnabled,
            sourceModelTensorBytes: source.sourceBytes, loadedTensorBytes: loadedBytes,
            largestHostTensorBytes: largestHostBytes, activeTensors: inventory.active,
            inertModules: inventory.inert, inertTensorBytes: summary.inertTensorBytes,
            storageCommitment: commitment, storageCommitmentSHA256: sha256(try canonicalJSONData(commitment)))
        return LoadedQwenLayerStage(model: model, plan: plan, stageIndex: stageIndex,
            receipt: receipt, activationDType: source.activationDType, vocabularySize: source.vocabularySize)
        // Verified descriptors close after this scope. Resident arrays do not
        // retain them; source deletion/replacement must not affect a loaded stage.
    }
}
