import Foundation

/// CPU metadata only. Published after verified load and before fresh request state.
/// This is phase evidence, never a completed cohort or a throughput sample.
struct QwenResidentSoloModelLoaded: Encodable {
    let kind = "qwen_resident_solo_model_loaded"
    let schemaVersion = 1
    let verifiedFullModelLoads = 1
    let freshRequestStateCreated = false
    let modelReleased = false
    let cohortCompleted = false
    let warmupCount = 1
    let measuredCount: Int
    let firstRequestID: UUID
    let firstRequestFingerprint: String
    let expectedTokenFileSHA256: String
    let source: QwenLongPrefillReferenceSource
    let sourceLoad: VerifiedQwenDiagnosticReceipt
    let publishedNanoseconds: UInt64

    init(preflight: QwenResidentSoloPreflight, source: QwenLongPrefillReferenceSource,
         sourceLoad: VerifiedQwenDiagnosticReceipt) {
        measuredCount = preflight.measuredCount
        firstRequestID = preflight.first.admission.request.requestID
        firstRequestFingerprint = preflight.first.admission.request.fingerprint
        expectedTokenFileSHA256 = preflight.expectedTokenFileSHA256
        self.source = source; self.sourceLoad = sourceLoad
        publishedNanoseconds = DispatchTime.now().uptimeNanoseconds
    }
}

/// The request has left its autorelease/lifecycle scope before this value exists.
/// A later failure retains this record but cannot qualify the incomplete cohort.
struct QwenResidentSoloRequestRetired: Encodable {
    let kind = "qwen_resident_solo_request_retired"
    let schemaVersion = 1
    let modelReleased = false
    let cohortCompleted = false
    let warmupCount = 1
    let measuredCount: Int
    let expectedTokenFileSHA256: String
    let request: QwenResidentSoloCohortRequest
    let kernelEligibility: QwenResidentSoloKernelEligibility
    let publishedNanoseconds: UInt64

    init(preflight: QwenResidentSoloPreflight, request: QwenResidentSoloCohortRequest,
         kernelEligibility: QwenResidentSoloKernelEligibility) {
        measuredCount = preflight.measuredCount
        expectedTokenFileSHA256 = preflight.expectedTokenFileSHA256
        self.request = request; self.kernelEligibility = kernelEligibility
        publishedNanoseconds = DispatchTime.now().uptimeNanoseconds
    }
}
