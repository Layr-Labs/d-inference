import Foundation

struct QwenLongPrefillResidentRankRequestReport: Encodable {
    let ordinal: Int
    let excludedWarmup: Bool
    let epoch: String
    let request: QwenLayerStageProfiledPrefillRecordedRequest
    let promptFileSHA256: String
    let agreement: QwenLayerStageProfiledPrefillStartAgreement.Descriptor
    let execution: QwenLongPrefillRankRequestResult
    let weightsRemainResident = true
}

struct QwenLongPrefillResidentRankReport: Encodable {
    let kind = "qwen_long_prefill_resident_rank_cohort", schemaVersion = 1
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
    let warmupCount: Int
    let requests: [QwenLongPrefillResidentRankRequestReport]
    let memory: [QwenStageMemoryObservation]
    let stageLoadCount = 1, allRequestStateRetired = true, modelReleased = true
    let correctnessOnly = true, throughputMeasurementValid = false
    let physicalTransferQualified = false, independentNumericalComparisonPerformed = false
    let physicalFusionAllocationLineageVerified = false
}
