//! Typed trust-verification outcomes and the challenge expectation shape.

use darkbloom_core::ids::TrustEpoch;

use crate::contracts::TrustVerdict;

/// A registration-time verification outcome.
#[derive(Debug, Clone)]
pub struct RegistrationVerdict {
    pub trust_epoch: TrustEpoch,
    pub verdict: TrustVerdict,
    /// base64 raw P-256 Secure Enclave public key from a *valid* blob; the
    /// challenge loop verifies against this key.
    pub se_public_key: Option<String>,
    /// Attested hardware serial from a *valid* blob (stable-identity input).
    pub serial_number: Option<String>,
}

/// A challenge-round verification outcome.
#[derive(Debug, Clone)]
pub struct ChallengeVerdict {
    pub trust_epoch: TrustEpoch,
    pub verdict: TrustVerdict,
    /// Whether the status fields were cryptographically bound by a verified
    /// `status_signature` (pre-v0.3.11 providers sign only nonce+timestamp;
    /// their status fields are advisory).
    pub status_fields_bound: bool,
}

/// What the session expects the provider to have signed for one challenge.
#[derive(Debug, Clone)]
pub struct ChallengeExpectation {
    /// base64 nonce string exactly as sent in the challenge frame.
    pub nonce: String,
    /// ISO 8601 timestamp string exactly as sent in the challenge frame.
    pub timestamp: String,
}

pub(super) fn untrusted(reason: impl Into<String>) -> TrustVerdict {
    TrustVerdict::Untrusted {
        reason: reason.into(),
    }
}
