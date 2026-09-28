import Foundation

enum QwenPrefillOwnerRole: String, Encodable, Sendable {
    case solo, rank0, rank1
}

/// Exact registered-long-profile selection. Identity contains CPU values only;
/// the caller validates the actual admitted request and frame before observing.
struct QwenPrefillOwnerIdentity: Equatable, Encodable, Sendable {
    let requestFingerprint: String
    let profile: String
    let role: QwenPrefillOwnerRole
    let frameSequence = 7
    let tokenOffset = 3584
    let tokenCount = 512
    let committedFrontier = 4096

    init(requestFingerprint: String, profile: String, role: QwenPrefillOwnerRole) throws {
        guard requestFingerprint.utf8.count == 64,
              requestFingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              profile == "long_prefill_8k_v1" else {
            throw QwenPrefillOwnerError("Invalid recorded request fingerprint or owner profile")
        }
        self.requestFingerprint = requestFingerprint
        self.profile = profile
        self.role = role
    }
}

enum QwenPrefillOwnerClockSource: String, Encodable {
    case dispatchUptimeNanoseconds = "DispatchTime.uptimeNanoseconds"
    case injectedTestClock = "injected_test_clock"
}

struct QwenPrefillOwnerEvent: Equatable, Encodable {
    let ordinal: Int
    let phase: String
    let tokenCount: Int
    let committedTokens: Int
    let localUptimeNanoseconds: UInt64
}

/// No model, native arrays, callbacks or mutable recorder escape in this value.
/// Seal is the caller's assertion of outer success, not an independent proof.
struct QwenPrefillOwnerTrace: Encodable {
    let kind = "qwen_prefill_selected_owner_trace", schemaVersion = 1
    let identity: QwenPrefillOwnerIdentity
    let clockSource: QwenPrefillOwnerClockSource
    let maximumEvents = 8
    let events: [QwenPrefillOwnerEvent]
    let firstLocalUptimeNanoseconds: UInt64
    let lastLocalUptimeNanoseconds: UInt64
    let traceSpanNanoseconds: UInt64
    let diagnosticOnly = true
    let includesRecorderOverhead = true
    let evaluationIntervalIncludesExistingErrorCheck = true
    let crossProcessClockAlignmentAsserted = false
    let gpuKernelTimeAsserted = false
    let gpuOverlapAsserted = false
    let modelReleaseAsserted = false
    let recorderIndependentlyVerifiesOuterSuccess = false
}

struct QwenPrefillOwnerError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
