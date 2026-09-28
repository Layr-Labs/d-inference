import Foundation

/// Copied metadata only, emitted after one verified stage load and before any
/// request permission or fresh request state. Rank cohort agreement precedes load.
struct QwenLongPrefillResidentRankReady: Encodable {
    let kind = "qwen_long_prefill_resident_rank_ready", schemaVersion = 1
    let rank: Int
    let worldSize = 2
    let transport: String
    let jacclConfiguration: QwenResidentJACCLConfiguration.Receipt?
    let cohortAgreement: QwenLongPrefillResidentCohortAgreement.Descriptor
    let cohortReadiness: QwenLongPrefillResidentCohortReadiness
    let sourceLoad: QwenLayerStageLoadReceipt
    let arithmeticEnvironment: QwenLongPrefillArithmeticEnvironment.Receipt
    let arithmeticEnvironmentSHA256: String
    let resourceAdmission: QwenRegistered9BLongPrefillAdmission.Receipt
    let requestCount: Int, warmupCount: Int
    let verifiedModelLoaded = true, freshRequestStateCreated = false
    let correctnessOnly = true, throughputMeasurementValid = false
    let physicalTransferQualified = false, independentNumericalComparisonPerformed = false
}
