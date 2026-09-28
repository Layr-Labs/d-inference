import Foundation

/// Scalar selection and copied final metadata only; no model, native array or
/// state bytes escape. Independent numerical comparison is external and post-run.
struct QwenLongPrefillSoloRequestResult: Encodable {
    let kind = "qwen_long_prefill_solo_request", schemaVersion = 1
    let correctnessOnly = true, throughputMeasurementValid = false
    let interprocessTransportUsed = false, physicalTransferQualified = false
    let independentNumericalComparisonPerformed = false
    let fullVocabularyValuesExported = false, nativeLogitBytesCompared = false
    let source: QwenLongPrefillReferenceSource
    let sourceLoad: VerifiedQwenDiagnosticReceipt
    let request: QwenLayerStageProfiledPrefillRecordedRequest
    let commits: [QwenLayerStageSoloPrefillCommit]
    let selection: QwenLayerStageSoloPrefillSelection
    let finalState: QwenRecordedState
    let finalLogits: QwenLayerStageSoloPrefillReference.Logits
    let timing: QwenLayerStageSoloPrefillTiming
    let completedFrames: Int, committedTokens: Int
    let perFrameStateCaptures = 0, perFrameLogitCaptures = 0
    let finalStateCaptures = 1, finalLogitCaptures = 1, nativeTokenSelections = 1
    let allRequestStateRetired = true
}

struct QwenLongPrefillSoloReady: Encodable {
    let kind = "qwen_long_prefill_solo_ready", schemaVersion = 1
    let correctnessOnly = true, throughputMeasurementValid = false
    let verifiedModelLoaded = true, freshRequestStateCreated = false
    let profile: QwenLayerStagePrefillProfile
    let profileFingerprint: String, promptFileSHA256: String
    let arithmeticEnvironmentSHA256: String, recordedRequestFingerprint: String
}

struct QwenLongPrefillSoloReport: Encodable {
    let kind = "qwen_long_prefill_solo_report", schemaVersion = 1
    let completed = true, correctnessOnly = true, throughputMeasurementValid = false
    let interprocessTransportUsed = false, physicalTransferQualified = false
    let allRequestStateRetired = true, modelReleased = true
    let profile: QwenLayerStagePrefillProfile
    let profileFingerprint: String, promptFileSHA256: String, promptTokenIDsSHA256: String
    let arithmeticEnvironment: QwenLongPrefillArithmeticEnvironment.Receipt
    let arithmeticEnvironmentSHA256: String
    let resourceAdmission: QwenRegistered9BLongPrefillAdmission.Receipt
    let execution: QwenLongPrefillSoloRequestResult
    let memory: [QwenStageMemoryObservation]
}
