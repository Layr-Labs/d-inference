import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Shared conservation/commitment assembly; callers already admitted their source and inventories.
func qwenLayerStageStorageCommitment(source: PreparedQwenLayerSource, originalConfiguration: Data,
    plan: QwenLayerStagePlan, inventories: [QwenStagePreparedInventory]
) throws -> QwenLayerStageStorageCommitment {
    let coverage = inventories.flatMap(\.active)
    guard coverage.count == source.tensors.count,
          Set(coverage.map(\.sourceName)) == Set(source.tensors.map(\.sourceName)),
          coverage.reduce(0, { $0 + $1.byteCount }) == source.sourceBytes else {
        throw ProbeError("Layer-stage inventories do not exactly conserve canonical source storage")
    }
    return QwenLayerStageStorageCommitment(schemaVersion: 1,
        verifiedAggregateSHA256: source.prepared.checkpoint.aggregate,
        sourceConfigurationSHA256: sha256(originalConfiguration), planSHA256: plan.fingerprint,
        sourceTensorManifestSHA256: source.sourceTensorManifestSHA256,
        sourceModelTensorBytes: source.sourceBytes,
        largestSourceTensorBytes: source.largestSourceBytes,
        sourceTensorCount: source.prepared.sourceTensorCount,
        canonicalTensorCount: source.tensors.count,
        bf16ConversionEnabled: source.bf16ConversionEnabled,
        stages: inventories.map(\.summary))
}

/// Materialize registered tensors with a mandatory resource check before each read.
func materializeVerifiedQwenLayerStage(source: PreparedQwenLayerSource, plan: QwenLayerStagePlan,
    stageIndex: Int, model: any LanguageModel, inventory: QwenStagePreparedInventory,
    commitment: QwenLayerStageStorageCommitment, check: () throws -> Void,
    beforeTensor: (QwenStageActiveTensor) throws -> Void
) throws -> LoadedQwenLayerStage {
    // All source/stage geometry, policies, inventory ownership and caps
    // have now passed. This is the first checkpoint tensor materialization.
    try source.prepared.checkpoint.checkUnchanged()
    try source.prepared.checkpoint.bypassTensorPayloadCache()
    var loadedBytes = 0, largestHostBytes = 0
    var readAccounting = CheckpointAlignedReadAccounting()
    for entry in inventory.active {
        try autoreleasepool {
            guard let tensor = source.prepared.canonical[entry.sourceName] else {
                throw ProbeError("Verified stage descriptor disappeared")
            }
            try beforeTensor(entry)
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
            // Match copySelectedTensor's settled ownership check: eval can
            // return before Metal completion handlers release their refs.
            Stream.gpu.synchronize()
            try check()
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
            try check()
            loadedBytes += read.copiedBytes
            largestHostBytes = max(largestHostBytes, read.largestHostTensorBytes)
            guard let accounting = read.readAccounting, accounting.selectedBytes == read.copiedBytes else {
                throw ProbeError("Selected-stage aligned read accounting is incomplete")
            }
            try readAccounting.merge(accounting)
        }
    }
    model.freeze()
    try check()
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
    guard loadedBytes == inventory.summary.loadedTensorBytes, readAccounting.selectedBytes == loadedBytes,
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
        storageCommitment: commitment, storageCommitmentSHA256: sha256(try canonicalJSONData(commitment)),
        selectedPayloadReadAccounting: readAccounting)
    return LoadedQwenLayerStage(model: model, plan: plan, stageIndex: stageIndex,
        receipt: receipt, activationDType: source.activationDType, vocabularySize: source.vocabularySize)
    // Verified descriptors close after this scope. Resident arrays do not
    // retain them; source deletion/replacement must not affect a loaded stage.
}
