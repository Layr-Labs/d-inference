import Foundation

extension ShadowKeyRecord {
    func mayGenerateKey(at now: Date) -> Bool {
        guard keyID.isEmpty else { return false }
        if now.timeIntervalSince(createdAt) >= 3600 { return true }
        return generationRetryAfter.map { now >= $0 } ?? false
    }

    /// Keep the persisted generation budget even when retiring an unusable key.
    mutating func retireEnrollment() {
        keyID = ""
        attested = false
        generationRetryAfter = nil
        pendingProof = nil
        pendingEnrollment = nil
        pendingStatus = nil
        pendingCreatedAt = nil
        attestationStartedAt = nil
        retryEnrollment = nil
    }
}

/// Only a completed native Apple callback with no key identifier permits an
/// earlier probe under the existing generation budget. An in-flight timeout,
/// cancellation or local gate's busy result may hide an issued key, so those
/// retain the pre-call one-hour marker.
func mayRetryKeyGeneration(after error: any Error) -> Bool {
    guard let callback = error as? AppleAppAttestFailure else { return false }
    return callback.failure == .appleUnavailable || callback.failure == .appleError
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
