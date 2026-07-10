//! The process-wide trust verifier: epoch minting plus the async
//! blocking-pool entry points for registration and challenge verification.
//! Invariant: the epoch is minted when verification STARTS (plan §9.1.6),
//! so a stale slow verification can never override a newer verdict.

use std::sync::atomic::{AtomicU64, Ordering};

use darkbloom_core::ids::TrustEpoch;
use darkbloom_protocol::json_v1::AttestationResponseMessage;

use crate::contracts::TrustVerdict;

use super::challenge::verify_challenge_response;
use super::registration::verify_registration_blob;
use super::types::{ChallengeExpectation, ChallengeVerdict, RegistrationVerdict};

/// Process-wide verifier. Holds no key material — it consumes public keys
/// and signatures owned by the caller and returns typed verdicts.
#[derive(Debug, Default)]
pub struct TrustVerifier {
    epoch: AtomicU64,
}

impl TrustVerifier {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Mints the next monotonic trust epoch. Public so a session can fence
    /// non-cryptographic downgrades (e.g. a chunk-integrity violation)
    /// through the same domain.
    pub fn next_epoch(&self) -> TrustEpoch {
        TrustEpoch::new(self.epoch.fetch_add(1, Ordering::Relaxed) + 1)
    }

    /// Verifies a registration attestation blob (the raw JSON bytes of the
    /// v1 `register` frame's `attestation` field, preserved unmodified).
    ///
    /// `registered_x25519_b64` is the X25519 encryption key from the same
    /// register frame; when the blob binds an `encryptionPublicKey`, the two
    /// must match (a mismatch means the encrypted transport key is not the
    /// attested one).
    pub async fn verify_registration(
        &self,
        attestation_json: Option<String>,
        registered_x25519_b64: String,
    ) -> RegistrationVerdict {
        let trust_epoch = self.next_epoch();
        let Some(raw) = attestation_json else {
            // Pilot policy: absence is a verdict, not an error. Whether an
            // unattested provider routes is the fleet's trust-floor decision.
            return RegistrationVerdict {
                trust_epoch,
                verdict: TrustVerdict::Untrusted {
                    reason: "no attestation presented".to_owned(),
                },
                se_public_key: None,
                serial_number: None,
            };
        };
        let outcome = tokio::task::spawn_blocking(move || {
            verify_registration_blob(&raw, &registered_x25519_b64)
        })
        .await;
        match outcome {
            Ok((verdict, se_key, serial)) => RegistrationVerdict {
                trust_epoch,
                verdict,
                se_public_key: se_key,
                serial_number: serial,
            },
            Err(_) => RegistrationVerdict {
                trust_epoch,
                verdict: TrustVerdict::Untrusted {
                    reason: "attestation verifier task failed".to_owned(),
                },
                se_public_key: None,
                serial_number: None,
            },
        }
    }

    /// Verifies one attestation-challenge response against the challenge the
    /// session actually sent (`expected`) and the SE key bound at
    /// registration. Mirrors Go `verifyChallengeResponse`.
    pub async fn verify_challenge(
        &self,
        se_public_key_b64: String,
        registered_x25519_b64: String,
        expected: ChallengeExpectation,
        response: AttestationResponseMessage,
    ) -> ChallengeVerdict {
        let trust_epoch = self.next_epoch();
        let outcome = tokio::task::spawn_blocking(move || {
            verify_challenge_response(
                &se_public_key_b64,
                &registered_x25519_b64,
                &expected,
                &response,
            )
        })
        .await;
        match outcome {
            Ok((verdict, bound)) => ChallengeVerdict {
                trust_epoch,
                verdict,
                status_fields_bound: bound,
            },
            Err(_) => ChallengeVerdict {
                trust_epoch,
                verdict: TrustVerdict::Untrusted {
                    reason: "challenge verifier task failed".to_owned(),
                },
                status_fields_bound: false,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn missing_attestation_is_a_verdict() {
        let out = TrustVerifier::new()
            .verify_registration(None, String::new())
            .await;
        assert!(matches!(out.verdict, TrustVerdict::Untrusted { .. }));
        assert!(out.trust_epoch.get() > 0);
    }

    #[test]
    fn epochs_are_strictly_monotonic() {
        let v = TrustVerifier::new();
        let a = v.next_epoch();
        let b = v.next_epoch();
        assert!(b > a);
    }
}
