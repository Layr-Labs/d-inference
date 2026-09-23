import Foundation

extension ShadowKeyRecord {
    /// Keep the persisted generation budget even when retiring an unusable key.
    mutating func retireEnrollment() {
        keyID = ""
        attested = false
        pendingProof = nil
        pendingEnrollment = nil
        pendingStatus = nil
        pendingCreatedAt = nil
        attestationStartedAt = nil
    }
}

func appAttestFailure(_ error: any Error) -> ShadowFailure {
    if error is CancellationError { return .cancelled }
    return (error as? AppleAppAttestFailure)?.failure ?? (error as? ShadowFailure) ?? .appleError
}

/// Apple permits reusing an enrollment key after serverUnavailable only. A
/// timeout/cancellation can hide a completed one-time attestation, so it is
/// uncertain too. Local admission/persistence failures do not consume a key.
func shouldRetireEnrollmentKey(after failure: ShadowFailure) -> Bool {
    switch failure {
    case .appleUnavailable, .busy, .keychainError, .invalidRequest, .notConfigured, .environmentMismatch:
        return false
    default:
        return true
    }
}
