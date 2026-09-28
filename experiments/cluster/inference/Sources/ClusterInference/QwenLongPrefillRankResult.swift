import Foundation

struct QwenLongPrefillRankAction: Encodable {
    let ordinal: Int
    let action: String
    let frameSequence: Int?
    let nativeCommittedTokens: Int
    let completedBoundaryCount: Int
    let explicitPreparedBoundarySlots: Int
    let pendingConsumedFrameSlots: Int
}

/// Copied CPU envelope bytes/identities and a scalar native commit. No payload.
struct QwenLongPrefillRankFrame: Encodable {
    let commit: QwenLayerStagePrefillCommit
    let exactEnvelopeJSON: String
    let envelopeFingerprint: String
    let envelopeWireBytesSHA256: String
}

struct QwenLongPrefillRankReadiness: Encodable {
    let kind = "qwen_long_prefill_rank_readiness"
    let agreementFingerprint: String
    let domain = "qwen-profiled-prefill-readiness-v1"
    let readinessMaterialSHA256: String
    let elements = 64, byteCount = 256
    let encoding = "sha256_hex_utf8_codepoints_int32_v1"
    let exchangeCompletedBeforeClock = true
    let freshRequestStateCreated = false
}

struct QwenLongPrefillRankTiming: Encodable {
    let clock = "DispatchTime.uptimeNanoseconds_rank_zero_only"
    let startEvent = "before_start_send_and_fresh_context_creation"
    let stopEvent = "after_final_consumed_and_selected_token_validation"
    let diagnosticOnly = true
    let startUptimeNanoseconds: UInt64
    let stopUptimeNanoseconds: UInt64
    let elapsedNanoseconds: UInt64
    let promptTokensPerFirstTokenSecond: Double
    let postStopThroughRequestCloseNanoseconds: UInt64
    let includesModelLoading = false, includesPreparedTokenDistribution = false
    let includesReadinessExchange = false
    let includesFreshRequestState = true, includesFreshContextAdmission = true
    let includesBoundaryValidationAndCopies = true, includesScalarTraceRecording = true
    let includesFinalTokenSelectionAndReturn = true
    let includesFinalDiagnosticCaptures = false, includesPostStopAcknowledgement = false
    let includesRequestRetirement = false
}

/// A successful result exists only after post-stop release and clean retirement.
/// Final numerical digests are compared by a separately pinned CPU oracle.
struct QwenLongPrefillRankRequestResult: Encodable {
    let kind = "qwen_long_prefill_rank_request", schemaVersion = 1
    let correctnessOnly = true, throughputMeasurementValid = false
    let interprocessTransportUsed = true, physicalTransferQualified = false
    let independentNumericalComparisonPerformed = false
    let profile: QwenLayerStagePrefillProfile
    let profileFingerprint: String
    let agreementFingerprint: String
    let identity: QwenLayerStageSessionIdentity
    let readiness: QwenLongPrefillRankReadiness
    let frames: [QwenLongPrefillRankFrame]
    let actions: [QwenLongPrefillRankAction]
    let selectedTokenID: Int
    let exactTokenPacketJSON: String
    let tokenPacketFingerprint: String
    let tokenPacketWireBytesSHA256: String
    let localSelection: QwenLayerStagePrefillTokenReceipt?
    let finalDigest: QwenLayerStageProfiledPrefillFinalDigest
    let completedFrames: Int, committedTokens: Int
    let preparedAheadFrames: Int
    let releasedOriginalBoundaryHandles: Int
    let postStopReleaseCompleted = true, allRequestStateRetired = true
    let originalWrapperReleaseIsNotProofOfNoStorageAliases = true
    let timing: QwenLongPrefillRankTiming?
}
