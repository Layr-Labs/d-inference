import Foundation

struct QwenDenseShortPairLoadResult {
    let loads: [QwenLayerStageLoadReceipt]
    let budget: QwenDenseShortPairLoadBudget
    let resources: [QwenDenseShortPairResourceDecision]
    let memory: [QwenStageMemoryObservation]
}

struct QwenDenseShortPairLoadReport: Encodable {
    let kind = "qwen_dense_short_pair_load_report", schemaVersion = 1, completed = true
    let model: QwenRegisteredDenseModel
    let referenceAdmissionFingerprint: String, recordedRequestFingerprint: String
    let loads: [QwenLayerStageLoadReceipt], budget: QwenDenseShortPairLoadBudget
    let initialResources: QwenDenseStageLoadOSObservation, releasedResources: QwenDenseStageLoadOSObservation
    let loadingResources: [QwenDenseShortPairResourceDecision]
    let memory: [QwenStageMemoryObservation], runtime: QwenDenseStageLoadRuntimeObservation
    let stageModelsLoaded = 2, fullCheckpointVerificationPasses = 1
    let bothStageModelsRetainedThroughPairLoad = true, activeStageParametersEvaluated = true
    let inertParametersMayRemainLazy = true, remainingInertAllowanceRetained = true
    let stageModelsReleased = true, verifiedFileOwnerReleased = true, cacheClearCompleted = true
    let actualResourceAdmissionPerformed = true, parentProcessFencingIndependentlyRequired = true
    let fullModelWeightsLoaded = false, forwardExecuted = false, requestStateCreated = false
    let referenceExecutionVerified = false, baselineComparisonPerformed = false, numericalParityEstablished = false
    let providerEligibilityEstablished = false, throughputMeasurementValid = false
    let wholeProcessMemorySafetyEstablished = false, physicalBufferLineageAttested = false
}
