import Foundation

struct QwenLayerStageSoloPrefillSelection: Encodable {
    let requestFingerprint: String
    let recordedRequestFingerprint: String
    let frame: QwenLayerStageFrame
    let committedTokens: Int
    let vocabularySize: Int
    let outputOrdinal = 0
    let policy = QwenLayerStageSoloPrefillReference.selectionPolicy
    let tokenID: Int
    let logitsShape: [Int]
    let logitsDType: String
    let selectionDType: String
    let allLogitsFinite: Bool
}

struct QwenLayerStageSoloPrefillCommit: Encodable {
    let frame: QwenLayerStageFrame
    let committedTokens: Int
    let outputKind: String
    let outputShape: [Int]
    let outputDType: String
}

struct QwenLayerStageSoloPrefillTiming: Encodable {
    let startUptimeNanoseconds: UInt64
    let stopUptimeNanoseconds: UInt64
    let elapsedNanoseconds: UInt64
    let promptTokensPerFirstTokenSecond: Double
    let postStopThroughRequestCloseNanoseconds: UInt64
    let includesFreshRequestState = true
    let includesFiniteArgmaxAndScalarReadback = true
    let includesBoundedCommitMetadata = true
    let includesTransport = false
    let excludesLoadReadinessFinalCaptureAndRetirement = true
}

/// CPU-only request result. The coordinator owns LoadedModel lifetime and must
/// separately prove final release; this value makes no modelReleased assertion.
struct QwenLayerStageSoloPrefillResult: Encodable {
    let kind = "qwen_layer_stage_solo_prefill_request_result"
    let schemaVersion = 1
    let correctnessOnly = true, throughputMeasurementValid = false
    let matchedChunkSolo = true, physicalTransferQualified = false
    let referenceFileSHA256: String
    let baselineEvidenceFingerprint: String
    let source: QwenLayerStageSoloPrefillReference.Source
    let request: QwenLayerStageRecordedRequest
    let commits: [QwenLayerStageSoloPrefillCommit]
    let selection: QwenLayerStageSoloPrefillSelection
    let referenceSelectedTokenID: Int
    let referenceMaximumTieCount: Int
    let finalLogits: QwenLayerStageSoloPrefillReference.Logits
    let finalState: QwenRecordedState
    let timing: QwenLayerStageSoloPrefillTiming
    let completedFrames: Int
    let committedTokens: Int
    let stateMetadataAndDigestsExact = true, logitMetadataAndDigestExact = true, selectedTokenExact = true
    let nativeLogitBytesCompared = false
    let perFrameStateCaptures = 0, perFrameLogitCaptures = 0
    let finalStateCaptures = 1, finalLogitCaptures = 1, nativeTokenSelections = 1
    let allRequestStateRetired = true
}
