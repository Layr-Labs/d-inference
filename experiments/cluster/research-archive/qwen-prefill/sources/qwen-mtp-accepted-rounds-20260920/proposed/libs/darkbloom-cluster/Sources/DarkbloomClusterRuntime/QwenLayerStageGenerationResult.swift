import Foundation

/// Small CPU-only return after both request-state retirements. The caller owns
/// resident model lifetime, external timing, numerical comparison and resources.
struct QwenLayerStageGenerationResult: Encodable {
    let schema = "qwen_stage_generation_result_v1"
    let agreementFingerprint: String
    let membershipEpoch: String
    let identity: QwenLayerStageSessionIdentity
    let selectedTokenIDs: [Int]
    let tokenChainSHA256: String
    let completedFrames: Int
    let committedTokens: Int
    let finishReason: QwenLayerStageGenerationFinishReason
    let bothRequestStatesRetired = true
    let modelRemainsResident = true
    var mtpEnabled = false
    let physicalTransferQualified = false
    let independentNumericalComparisonPerformed = false
    let externalTTFTMeasured = false
    // Nil is omitted, preserving the serial result's existing encoded shape.
    var prefillSchedule: QwenGenerationPrefillSummary? = nil
}
