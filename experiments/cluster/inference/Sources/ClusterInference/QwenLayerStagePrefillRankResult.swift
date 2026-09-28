import Foundation

struct QwenLayerStagePrefillRankAction: Encodable {
    let ordinal: Int
    let action: String
    let frameSequence: Int?
    let nativeCommittedTokens: Int
    let completedBoundaryCount: Int
    let explicitPreparedBoundarySlots: Int
    let pendingConsumedFrameSlots: Int
}

struct QwenLayerStagePrefillRankFrame: Encodable {
    let commit: QwenLayerStagePrefillCommit
    let exactEnvelopeJSON: String
    let envelopeSHA256: String
}

struct QwenLayerStagePrefillRankTiming: Encodable {
    let clock = "DispatchTime.uptimeNanoseconds_rank_zero_only"
    let startEvent = "before_start_send_and_fresh_context_creation"
    let stopEvent = "after_final_consumed_and_selected_token_validation"
    let diagnosticOnly = true
    let startUptimeNanoseconds: UInt64
    let stopUptimeNanoseconds: UInt64
    let elapsedNanoseconds: UInt64
    let promptTokensPerFirstTokenSecond: Double
    let postStopThroughRequestCloseNanoseconds: UInt64
    let includesModelLoading = false
    let includesPreparedTokenDistribution = false
    let includesFreshRequestState = true
    let includesBoundaryValidationAndCopies = true
    let includesScalarTraceRecording = true
    let includesFinalTokenSelectionAndReturn = true
    let includesFinalDiagnosticCaptures = false
    let includesPostStopAcknowledgement = false
    let includesRequestRetirement = false
}

struct QwenLayerStagePrefillRankRequestResult: Encodable {
    let kind = "qwen_layer_stage_prefill_rank_request"
    let agreementFingerprint: String
    let identity: QwenLayerStageSessionIdentity
    let frames: [QwenLayerStagePrefillRankFrame]
    let actions: [QwenLayerStagePrefillRankAction]
    let selectedTokenID: Int
    let exactTokenPacketJSON: String
    let tokenPacketSHA256: String
    let localSelection: QwenLayerStagePrefillTokenReceipt?
    let finalLogits: QwenLayerStagePrefillLogitMetadata?
    let finalStateEntries: [QwenRecordedState.Entry]
    let finalStateLogicalBytes: Int
    let finalStateSHA256: String
    let completedFrames: Int
    let committedTokens: Int
    let preparedAheadFrames: Int
    let releasedOriginalBoundaryHandles: Int
    let perFrameStateSnapshots = 0
    let perFrameLogitCaptures = 0
    let finalStateSnapshots = 1
    let finalLogitCaptures: Int
    let localTokenSelections: Int
    let postStopReleaseCompleted = true
    let allRequestStateRetired = true
    let timing: QwenLayerStagePrefillRankTiming?
}
