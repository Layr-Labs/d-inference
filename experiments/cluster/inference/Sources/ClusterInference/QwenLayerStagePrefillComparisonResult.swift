import Foundation

/// Execution retains these small host commits, never per-frame cache or logit
/// snapshots. Both entries belong to the same complete prompt frontier.
struct QwenLayerStagePrefillFrameComparison: Encodable {
    let frame: QwenLayerStageFrame
    let committedTokens: Int
    let stageCommits: [QwenLayerStagePrefillCommit]
}

struct QwenLayerStagePrefillTokenComparison: Encodable {
    let policy: String
    let baselineTokenID: Int
    let selectedTokenID: Int
    let maximumLogit: Float
    let maximumTieCount: Int
    let tokenExact: Bool
}

/// Counts describe this helper's explicit diagnostic calls. They do not count
/// or exclude the unchanged Session/boundary hashes, copies and root checks.
struct QwenLayerStagePrefillCaptureCounts: Encodable {
    let perFrameStateSnapshots: Int
    let perFrameLogitCaptures: Int
    let finalStateSnapshots: Int
    let finalLogitCaptures: Int
    let nativeTokenSelections: Int
    let nativeBoundaryCopies: Int
}

/// CPU-only terminal evidence. Full native vocabulary bytes are compared in
/// scope, then released; only their metadata/SHA is encoded in this result.
struct QwenLayerStagePrefillComparisonResult: Encodable {
    let kind = "qwen_layer_stage_prefill_compute_comparison"
    let correctnessOnly = true
    let throughputMeasurementValid = false
    let sequentialOneProcessOnly = true
    let nativeBoundaryBytesCopied = true
    let baselineEvidenceSHA256: String
    let requestSHA256: String
    let source: QwenRecordedSourceIdentity
    let stageStorageCommitmentSHA256: String
    let stageIdentities: [QwenLayerStageSessionIdentity]
    let frames: [QwenLayerStagePrefillFrameComparison]
    let completedFrames: Int
    let committedTokens: Int
    let token: QwenLayerStagePrefillTokenReceipt
    let tokenComparison: QwenLayerStagePrefillTokenComparison
    let finalLogits: QwenLayerStagePrefillLogitMetadata
    let finalState: QwenRecordedState
    let stateMetadataAndDigestsExact: Bool
    let nativeLogitBytesExact: Bool
    let captureCounts: QwenLayerStagePrefillCaptureCounts
    let allRequestStateRetired: Bool
}
