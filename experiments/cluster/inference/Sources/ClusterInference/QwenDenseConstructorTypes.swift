import Foundation

/// Actual lazy constructor metadata. Logical bytes are shape*dtype bytes, not
/// evaluated storage, active allocation, RSS, or expected post-load dtype.
struct QwenDenseConstructorParameter: Encodable, Equatable {
    let name: String, shape: [Int], constructorDType: String, logicalByteCount: Int
}

struct QwenDenseConstructorObservation: Encodable {
    let role: String, layerCount: Int, configurationSHA256: String
    let parameters: [QwenDenseConstructorParameter]
    let parameterMetadataSHA256: String, logicalParameterBytes: Int
    let modelReleased: Bool
    let parameterValuesEvaluated = false, checkpointWeightsInstalled = false
    let logicalBytesAreAllocationMeasurement = false
}

/// These existing records describe source mapping and expected post-load
/// metadata; they do not assert that active weights were installed or evaluated.
struct QwenDenseConstructorStage: Encodable {
    let constructor: QwenDenseConstructorObservation
    let expectedActiveTensors: [QwenStageActiveTensor]
    let installedLazyInertModules: [QwenStageInertModule]
    let expectedPostLoadSummary: QwenStageStorageSummary
    let actualLoadedInventoryEstablished = false
}

struct QwenDenseConstructorReport: Encodable {
    let kind = "qwen_dense_constructor_report", schemaVersion = 1
    let completed = true, correctnessOnly = true, throughputMeasurementValid = false
    let model: QwenRegisteredDenseModel
    let scope: String, profileFingerprint: String, planSHA256: String
    let configurationSHA256: String, manifestSHA256: String, verifiedAggregateSHA256: String
    let canonicalInventorySHA256: String
    let sourceTensorCount: Int, sourceTensorBytes: Int, largestSourceTensorBytes: Int
    let sourceTensors: [QwenStageSourceTensor]
    let sourceTensorManifestSHA256: String, expectedSourceParameterLayoutSHA256: String
    let arithmeticEnvironment: QwenLongPrefillArithmeticEnvironment.Receipt
    let fullConstructor: QwenDenseConstructorObservation
    let stages: [QwenDenseConstructorStage]
    let fullCheckpointVerificationPasses = 1, constructorsInspected = 3
    let allConstructorModelsReleased = true, verifiedFileOwnerReleased = true, cacheClearCompleted = true
    let checkpointFileBytesHashed = true, sourceTensorPayloadsMaterialized = false
    let forwardExecuted = false, requestStateCreated = false, loadedStageReceiptProduced = false
    let nativeConstructorOperationsUsed = true, nativeAllocationFree = false
    let parameterValuesEvaluated = false, numericalParityEstablished = false
    let providerEligibilityEstablished = false, independentResourceAdmissionEstablished = false
    let weightMaterializationAuthorized = false, forwardExecutionAuthorized = false
    let isWholeProcessMemoryBound = false, physicalTransferQualified = false
}
