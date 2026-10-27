import Foundation

struct Gemma4LocalMTPCohortSample: Encodable {
    let requestID: String, scopeSHA256: String, selectedTokenIDsSHA256: String
    let binding: Gemma4ShortSessionBinding
    let generation: Gemma4LocalMTPSample
    let evidence: Gemma4LocalMTPRequestEvidence
    let requestStateRetired = true
    // Conditioning equality proves assistant arithmetic only. Timing and target
    // batched acceptance remain experimental until separately compared to solo.
    let performanceQualified = false, modelNumericsQualified = false
}

struct Gemma4LocalMTPCohortReport: Encodable {
    let schema = "gemma4_local_mtp_cohort_result_v1"
    let configuration: Gemma4LocalMTPJob
    let benchmarkJob: Gemma4BenchmarkJob
    let scopeSHA256: String, ordinaryInputScopeSHA256: String, planSHA256: String
    let sourceLoad: Gemma4ForwardLoadReceipt, assistantLoad: Gemma4AssistantLoadReceipt
    let loadStartedNanoseconds: UInt64, targetLoadCompletedNanoseconds: UInt64
    let assistantLoadCompletedNanoseconds: UInt64, probeCompletedNanoseconds: UInt64
    let samples: [Gemma4LocalMTPCohortSample]
    let resources: Gemma4BenchmarkResourceReceipt, auxiliaryResources: Gemma4MTPAuxiliaryReceipt
    let files: [Gemma4ShortFile]
    let conditioningQualificationRequested: Bool, conditioningQualificationPassed: Bool
    let denseProjection: Gemma4MTPDenseProjection.Summary?
    let measuredRequests = 3, warmupRequests = 1
    let mtpEnabled = true, remoteAssistant = false, nativeExecuted = true
    let modelReleased = true, assistantReleased = true
    let targetBatchNumericsQualified = false, numericalComparisonPerformed = false, performanceQualified = false
    let runtimeServingEnabled = false, encryptedRDMAEstablished = false
    let physicalProcessOrLeaseRetirementEstablished = false
}
