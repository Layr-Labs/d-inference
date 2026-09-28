import Foundation

enum QwenPrefillPhaseRole: String, Encodable {
    case rank0, rank1, solo
}

/// CPU correlation only. This does not admit a model or request geometry.
struct QwenPrefillPhaseIdentity: Equatable, Encodable {
    /// Long-owner hooks use the recorded request fingerprint, including the
    /// admitted prompt/history, rather than the geometry-only request hash.
    let requestFingerprint: String
    let profile: String
    let role: QwenPrefillPhaseRole

    init(requestFingerprint: String, profile: String, role: QwenPrefillPhaseRole) throws {
        guard requestFingerprint.utf8.count == 64,
              requestFingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (1...64).contains(profile.utf8.count),
              profile.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 95 }) else {
            throw QwenPrefillPhaseError("Invalid phase identity")
        }
        self.requestFingerprint = requestFingerprint; self.profile = profile; self.role = role
    }
}

struct QwenPrefillPhaseEvent: Encodable {
    let ordinal: Int
    let phase: String
    let frameSequence: Int?
    let committedTokens: Int
    let localUptimeNanoseconds: UInt64
}

enum QwenPrefillPhaseClockSource: String, Encodable {
    case dispatchUptimeNanoseconds = "DispatchTime.uptimeNanoseconds"
    case injectedTestClock = "injected_test_clock"
}

/// Only copied CPU values escape. No closure, native array or model reference.
struct QwenPrefillPhaseTrace: Encodable {
    let kind = "qwen_prefill_local_phase_trace", schemaVersion = 1
    let identity: QwenPrefillPhaseIdentity
    let clockSource: QwenPrefillPhaseClockSource
    let maximumEvents: Int
    let events: [QwenPrefillPhaseEvent]
    let firstLocalUptimeNanoseconds: UInt64
    let lastLocalUptimeNanoseconds: UInt64
    let traceSpanNanoseconds: UInt64
    let diagnosticOnly = true
    let includesRecorderOverhead = true
    let crossProcessClockAlignmentAsserted = false
    let gpuOverlapAsserted = false
    let modelReleaseAsserted = false
    let recorderIndependentlyVerifiesRequestRetirement = false
}

struct QwenPrefillPhaseError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
