import DarkbloomClusterProtocol
import Foundation

struct QwenResidentMTPLoadCheckAdmission: Encodable {
    let schema = "qwen_resident_mtp_selected_load_check_v1"
    let type = "admitted"
    let identity: ClusterWorkerIdentity
    let rank: Int, stageCut: Int
    let deadlineUptimeNanoseconds: UInt64
    let manifestSHA256: String, planSHA256: String
    let arithmetic: QwenLongPrefillArithmeticEnvironment.Receipt
    let arithmeticSHA256: String
    let jacclConfiguration: QwenResidentJACCLConfiguration.Receipt
    let allocatorPolicy: String
    let initialResources: QwenDenseStageLoadOSObservation
    let collectiveInitialized = false, bilateralAdmissionPerformed = false
    let selectedPayloadMaterialized = false, generationEnabled = false

    init(_ admission: QwenResidentAdmission, initial: QwenDenseStageLoadOSObservation) {
        let value = admission.configuration
        identity = value.identity; rank = value.rank; stageCut = value.stageCut
        deadlineUptimeNanoseconds = value.deadlineUptimeNanoseconds
        manifestSHA256 = admission.specification.manifestSHA256
        planSHA256 = admission.plan.fingerprint
        arithmetic = admission.arithmetic; arithmeticSHA256 = admission.arithmeticSHA256
        jacclConfiguration = admission.jaccl.receipt
        allocatorPolicy = value.allocatorPolicy.rawValue; initialResources = initial
    }
}

struct QwenResidentMTPLoadCheckPayload: Encodable {
    let targetLoad: QwenLayerStageLoadReceipt
    let mtpLoad: QwenResidentMTPLoadReceipt
    let loadedResources: QwenDenseStageLoadOSObservation
    let loadedMemory: QwenStageMemoryObservation
}

struct QwenResidentMTPLoadCheckReport: Encodable {
    let schema = "qwen_resident_mtp_selected_load_check_v1"
    let type = "report", completed = true
    let admission: QwenResidentMTPLoadCheckAdmission
    let payload: QwenResidentMTPLoadCheckPayload
    let initialMemory: QwenStageMemoryObservation
    let releasedMemory: QwenStageMemoryObservation
    let releasedResources: QwenDenseStageLoadOSObservation
    let runtime: QwenDenseStageLoadRuntimeObservation
    let targetOwnerReleased = true, assistantOwnerReleased = true
    let verifiedFileOwnerReleased = true, cacheClearCompleted = true
    let targetLoadReceiptPreserved = true
    let additionalBuffersCheckedAtMaterialization = true
    let collectiveInitialized = false, bilateralAdmissionPerformed = false
    let forwardExecuted = false, requestStateCreated = false, generationEnabled = false
    let tensorValuesIndependentlyCompared = false, numericalParityEstablished = false
    let pairwiseBufferAddressesIndependentlyCompared = false
    let providerEligibilityEstablished = false, throughputMeasurementValid = false
    let parentProcessFencingIndependentlyRequired = true
}
