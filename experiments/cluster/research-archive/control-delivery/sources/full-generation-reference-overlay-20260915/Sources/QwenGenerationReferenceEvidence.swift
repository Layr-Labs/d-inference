import Foundation

struct QwenGenerationReferenceTokenEvidence: Encodable {
    let outputOrdinal: Int
    let frame: QwenLayerStageFrame
    let committedTokens: Int
    let tokenID: Int
    let maximumTieCount: Int
    let maximumLogit: Float
    let logitsShape: [Int]
    let logitsDType: String
    let logitsByteCount: Int
    let logitsLogicalBytesSHA256: String
    let policy = "mlx_argmax_all_axes_with_finite_guard_v1"
    let cpuCrosscheckPolicy = "finite_maximum_lowest_vocabulary_index_v1"
    let nativeSelectionMatchesCapturedFullRow = true
}

struct QwenGenerationReferenceTiming: Encodable {
    let clock = "DispatchTime.uptimeNanoseconds.same_process"
    let requestStartNanoseconds: UInt64
    let firstSelectedTokenNanoseconds: UInt64
    let finalSelectedTokenNanoseconds: UInt64
    let retiredNanoseconds: UInt64
    let includesLoading = false
    let includesSourceAndResourceAdmission = false
    let firstTokenIncludesFreshStateConstruction = true
    let continuationIncludesPriorEvidenceCapture = true
    let externalTTFTMeasured = false
    let throughputMeasurementValid = false
}

/// CPU-only return. Every target row was copied and checked, but only compact
/// row identities and the last complete row are retained. The caller still owns
/// the full model; this result claims request retirement, not model release.
struct QwenGenerationReferenceResult: Encodable {
    let schema = "qwen_full_generation_reference_v1"
    let source: QwenLongPrefillReferenceSource
    let sourceLoad: VerifiedQwenDiagnosticReceipt
    let promptFileSHA256: String
    let promptTokenIDsSHA256: String
    let requestID: UUID
    let requestFingerprint: String
    let profile: QwenLayerStageGenerationProfile
    let promptCount: Int
    let chunkSize: Int
    let requestedOutputCount: Int
    let maximumTokens: Int
    let stopTokenIDs: [Int]
    let requirements: QwenGenerationReferenceRequirements
    let selectedTokenIDs: [Int]
    let selectedTokenIDsSHA256: String
    let finishReason: QwenLayerStageGenerationFinishReason
    let completedFrames: Int
    let committedTokens: Int
    let tokens: [QwenGenerationReferenceTokenEvidence]
    let finalLogits: QwenRecordedLogits
    let finalState: QwenRecordedState
    let timing: QwenGenerationReferenceTiming
    let finalStateCaptures = 1
    let allRequestStateRetired = true
    let modelRemainsResident = true
    let fullVocabularyValuesRetainedForEveryToken = false
    let mtpEnabled = false
    let correctnessOnly = true
    let candidateNumericalComparisonPerformed = false
    let physicalTransferQualified = false
}
