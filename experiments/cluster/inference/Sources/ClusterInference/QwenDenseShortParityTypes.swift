import Foundation

/// Only immutable CPU evidence crosses either native owner boundary.
struct QwenDenseShortBaselineCheckpoint: Encodable {
    let kind = "qwen_dense_short_baseline_checkpoint", schemaVersion = 1
    let model: QwenRegisteredDenseModel
    let referenceAdmissionFingerprint: String, promptSHA256: String, teacherSHA256: String
    let baseline: QwenLayerStageBaselineEvidence
    let load: VerifiedQwenDiagnosticReceipt, budget: QwenDenseShortReferenceLoadBudget
    let initialResources: QwenDenseStageLoadOSObservation, releasedResources: QwenDenseStageLoadOSObservation
    let resourceObservations: [QwenDenseShortReferenceResourceDecision]
    let memory: [QwenStageMemoryObservation], runtime: QwenDenseStageLoadRuntimeObservation
    let promptCount = 3, chunkSize = 2, teacherCount = 1, outputCount = 2, maximumTokens = 5
    let committedFrontiers = [2, 3, 4]
    let fullModelsLoaded = 1, fullCheckpointVerificationPasses = 1
    let fullModelReleasedBeforeStageLoading = true, verifiedFileOwnerReleased = true, cacheClearCompleted = true
    let forwardExecuted = true, embeddingArithmeticExecuted = true, requestStateRetired = true
    let actualResourceAdmissionPerformed = true, parentProcessFencingIndependentlyRequired = true
    let correctnessOnly = true, numericalParityEstablished = false, throughputMeasurementValid = false
    let providerEligibilityEstablished = false, wholeProcessMemorySafetyEstablished = false

    init(admission: QwenDenseShortReferenceAdmission, baseline: QwenLayerStageBaselineEvidence,
        loading: QwenDenseShortReferenceLoadResult,
        initialResources: QwenDenseStageLoadOSObservation, releasedResources: QwenDenseStageLoadOSObservation,
        memory: [QwenStageMemoryObservation], runtime: QwenDenseStageLoadRuntimeObservation
    ) {
        model = admission.metadata.specification.model; referenceAdmissionFingerprint = admission.fingerprint
        promptSHA256 = admission.promptSHA256; teacherSHA256 = admission.teacherSHA256
        self.baseline = baseline; load = loading.receipt; budget = loading.budget
        self.initialResources = initialResources; self.releasedResources = releasedResources
        resourceObservations = loading.resources; self.memory = memory; self.runtime = runtime
    }
}

struct QwenDenseShortPairComparisonResult {
    let loading: QwenDenseShortPairLoadResult
    let comparison: QwenLayerStageRecordedComparison
}

struct QwenDenseShortPairComparisonReport: Encodable {
    let comparison: QwenLayerStageRecordedComparison
    let stageLoads: [QwenLayerStageLoadReceipt], budget: QwenDenseShortPairLoadBudget
    let initialResources: QwenDenseStageLoadOSObservation, releasedResources: QwenDenseStageLoadOSObservation
    let resourceObservations: [QwenDenseShortPairResourceDecision]
    let memory: [QwenStageMemoryObservation], runtime: QwenDenseStageLoadRuntimeObservation
    let stageModelsLoaded = 2, fullCheckpointVerificationPasses = 1
    let stageModelsReleased = true, verifiedFileOwnerReleased = true, cacheClearCompleted = true
    let requestStateRetired = true, remainingInertAllowanceRetained = true
    let physicalBufferLineageAttested = false

    init(loading: QwenDenseShortPairLoadResult, comparison: QwenLayerStageRecordedComparison,
        initialResources: QwenDenseStageLoadOSObservation, releasedResources: QwenDenseStageLoadOSObservation,
        memory: [QwenStageMemoryObservation], runtime: QwenDenseStageLoadRuntimeObservation
    ) {
        self.comparison = comparison; stageLoads = loading.loads; budget = loading.budget
        self.initialResources = initialResources; self.releasedResources = releasedResources
        resourceObservations = loading.resources; self.memory = memory; self.runtime = runtime
    }
}

struct QwenDenseShortParityReport: Encodable {
    let kind = "qwen_dense_short_parity_report", schemaVersion = 1, completed = true
    let model: QwenRegisteredDenseModel
    let referenceAdmissionFingerprint: String, recordedRequestFingerprint: String
    let promptSHA256: String, teacherSHA256: String, baselineEvidenceSHA256: String
    let pair: QwenDenseShortPairComparisonReport
    let promptCount = 3, chunkSize = 2, teacherCount = 1, outputCount = 2, maximumTokens = 5
    let committedFrontiers = [2, 3, 4]
    let correctnessOnly = true, numericalParityEstablished = true, sequentialOneProcessOnly = true
    let fullModelReleasedBeforeStageLoading = true, allRequestStateRetired = true
    let actualResourceAdmissionPerformed = true, parentProcessFencingIndependentlyRequired = true
    let tensorValuesIndependentlyCompared = false, throughputMeasurementValid = false
    let providerEligibilityEstablished = false, wholeProcessMemorySafetyEstablished = false
}
