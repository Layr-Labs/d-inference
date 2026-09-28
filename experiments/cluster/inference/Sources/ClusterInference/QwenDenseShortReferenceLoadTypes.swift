import Foundation

struct QwenDenseShortReferenceLoadResult {
    let receipt: VerifiedQwenDiagnosticReceipt
    let budget: QwenDenseShortReferenceLoadBudget
    let resources: [QwenDenseShortReferenceResourceDecision]
    let memory: [QwenStageMemoryObservation]
}

struct QwenDenseShortReferenceLoadReport: Encodable {
    let kind = "qwen_dense_short_reference_load_report", schemaVersion = 1, completed = true
    let model: QwenRegisteredDenseModel
    let admissionFingerprint: String, recordedRequestFingerprint: String
    let load: VerifiedQwenDiagnosticReceipt, budget: QwenDenseShortReferenceLoadBudget
    let initialResources: QwenDenseStageLoadOSObservation, releasedResources: QwenDenseStageLoadOSObservation
    let loadingResources: [QwenDenseShortReferenceResourceDecision]
    let memory: [QwenStageMemoryObservation], runtime: QwenDenseStageLoadRuntimeObservation
    let fullReferencePayloadMaterialized = true, fullModelParametersEvaluated = true
    let fullModelsLoaded = 1, fullCheckpointVerificationPasses = 1
    let modelReleased = true, verifiedFileOwnerReleased = true, cacheClearCompleted = true
    let actualResourceAdmissionPerformed = true, parentProcessFencingIndependentlyRequired = true
    let forwardExecuted = false, requestStateCreated = false, embeddingArithmeticExecuted = false
    let numericalParityEstablished = false, tensorValuesIndependentlyCompared = false
    let providerEligibilityEstablished = false, throughputMeasurementValid = false
    let wholeProcessMemorySafetyEstablished = false
}

