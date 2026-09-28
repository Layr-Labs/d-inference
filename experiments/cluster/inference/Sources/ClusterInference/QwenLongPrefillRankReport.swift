import Foundation

struct QwenLongPrefillRankReady: Encodable {
    let kind = "qwen_long_prefill_rank_ready", schemaVersion = 1
    let epoch: String, rank: Int
    let worldSize = 2, transport = "loopback-test", backend = "ring"
    let flow = QwenLayerStageProfiledPrefillMeasurementFlow.name
    let envelopeVersion = QwenLayerStageProfiledPrefillMeasurementFlow.version
    let modelsReadyAgreementValidated = true, freshRequestStateCreated = false
    let agreementFingerprint: String
    let agreement: QwenLayerStageProfiledPrefillStartAgreement.Descriptor
    let promptFileSHA256: String
}

struct QwenLongPrefillRankReport: Encodable {
    let kind = "qwen_long_prefill_rank_report", schemaVersion = 1
    let epoch: String, rank: Int
    let worldSize = 2, transport = "loopback-test", backend = "ring"
    let flow = QwenLayerStageProfiledPrefillMeasurementFlow.name
    let envelopeVersion = QwenLayerStageProfiledPrefillMeasurementFlow.version
    let completed = true, correctnessOnly = true, throughputMeasurementValid = false
    let modelForwardCompared = false, physicalTransferQualified = false
    let agreementFingerprint: String
    let agreement: QwenLayerStageProfiledPrefillStartAgreement.Descriptor
    let sourceLoad: QwenLayerStageLoadReceipt
    let request: QwenLayerStageProfiledPrefillRecordedRequest
    let promptFileSHA256: String
    let arithmeticEnvironment: QwenLongPrefillArithmeticEnvironment.Receipt
    let arithmeticEnvironmentSHA256: String
    let resourceAdmission: QwenRegistered9BLongPrefillAdmission.Receipt
    let execution: QwenLongPrefillRankRequestResult
    let allRequestStateRetired = true, modelReleased = true
    let memory: [QwenStageMemoryObservation]
}
