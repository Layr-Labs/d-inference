import Foundation

/// Typed closed records use the shared lexical JSONEncoder policy. No field,
/// arithmetic value, source commitment or ordinary capability byte is inferred.
struct QwenProtectedResourcePolicyRecord: Encodable {
    let schema: String
    let profile: String
    let hardwareModel: String
    let osBuild: String
    let physicalMemoryBytes: [Int]
    let allocatorPolicy: String
    let suite: String
    let maximumInFlightOperations: Int
    let separateDirectionCodecs: Bool
    let maximumPlaintextBytes: Int
    let maximumFrameBytes: Int
    let maximumRecordsPerDirection: UInt64
    let maximumCumulativePlaintextBytesPerDirection: UInt64
    let observedPhysicalIncrementBytes: Int
    let observedNativeIncrementBytes: Int
    let meshBackingBytes: Int
    let logicalHostCopies: Int
    let keyAndMetadataAllowanceBytes: Int
    let operationalSafetyBytes: Int
    let numericalEvidenceHostAllowanceBytes: Int
    let numericalEvidenceMaximumEncodedBytes: Int
    let numericalEvidenceSchema: String
    let additionalHostBytes: Int
    let additionalNativeBytes: Int
    let minimumActualFreeBytes: Int
    let loadingHeadroomBytes: Int
    let allocatorHeadroomBytes: Int
    let allocationReviews: [String]
    let sourceBindings: [String: String]
    let allocationNativeSHA256: String
    let wholeProcessPeakProven: Bool
    let rdmaMeasured: Bool
    let servingEnabled: Bool
}

struct QwenProtectedRuntimeDescriptionRecord: Encodable {
    let schema: String
    let staticProfile: String
    let runtimeBinarySHA256: String
    let ordinaryCapabilityBase64: String
    let capabilitySHA256: String
    let selectedPlanSHA256: String
    let profileFingerprint: String
    let resourcePolicySHA256: String
    let resourcePolicyBase64: String
    let stageCut: Int
    let prefillSchedule: String
    let promptTokens: Int
    let chunkTokens: Int
    let outputTokens: Int
    let stopTokenIDs: [Int]
    let maximumPlaintextBytes: Int
    let maximumFrameBytes: Int
    let maximumRecordsPerDirection: UInt64
    let maximumCumulativePlaintextBytesPerDirection: UInt64
    let bootstrapProfile: String
    let sourceBindings: [String: String]
    let allocationReviews: [String]
    let experimentalExecutionOnly: Bool
    let wholeProcessPeakProven: Bool
    let rdmaMeasured: Bool
    let servingEnabled: Bool
}

