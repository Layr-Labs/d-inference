import Foundation

/// Only copied source/resource metadata escapes the loaded-before-command seam.
struct QwenLongPrefillResidentSoloReady: Encodable {
    let kind = "qwen_long_prefill_resident_solo_ready", schemaVersion = 1
    let source: QwenLongPrefillReferenceSource
    let sourceLoad: VerifiedQwenDiagnosticReceipt
    let arithmeticEnvironment: QwenLongPrefillArithmeticEnvironment.Receipt
    let arithmeticEnvironmentSHA256: String
    let resourceAdmission: QwenRegistered9BLongPrefillAdmission.Receipt
    let requestCount: Int, warmupCount: Int
    let verifiedModelLoaded = true, freshRequestStateCreated = false
    let correctnessOnly = true, throughputMeasurementValid = false
    let physicalTransferQualified = false, independentNumericalComparisonPerformed = false
}

struct QwenLongPrefillResidentSoloRequestReport: Encodable {
    let step: QwenLongPrefillResidentRequestStep
    let execution: QwenLongPrefillSoloRequestResult
    let weightsRemainResident = true
}

struct QwenLongPrefillResidentSoloReport: Encodable {
    let kind = "qwen_long_prefill_resident_solo_cohort", schemaVersion = 1
    let sourceLoad: VerifiedQwenDiagnosticReceipt
    let arithmeticEnvironment: QwenLongPrefillArithmeticEnvironment.Receipt
    let arithmeticEnvironmentSHA256: String
    let resourceAdmission: QwenRegistered9BLongPrefillAdmission.Receipt
    let warmupCount: Int
    let requests: [QwenLongPrefillResidentSoloRequestReport]
    let memory: [QwenStageMemoryObservation]
    let fullModelLoadCount = 1, allRequestStateRetired = true, modelReleased = true
    let correctnessOnly = true, throughputMeasurementValid = false
    let interprocessTransportUsed = false, physicalTransferQualified = false
    let independentNumericalComparisonPerformed = false
    let physicalFusionAllocationLineageVerified = false
}
