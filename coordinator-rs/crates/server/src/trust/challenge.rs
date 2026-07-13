//! Fresh challenge and canonical status signature verification.

use std::sync::Arc;

use darkbloom_coordinator_protocol::v1::AttestationResponse;
use thiserror::Error;

use crate::crypto::X25519PublicKey;

use super::{
    RegistrationTrust, TrustFloor, TrustLevel,
    registration::{RegistrationVerificationError, verify_signature},
};

/// Exact challenge values generated and retained by the coordinator.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ChallengeExpectation {
    /// Single-use random nonce text sent on the wire.
    pub nonce: Arc<str>,
    /// Coordinator timestamp text sent with that nonce.
    pub timestamp: Arc<str>,
}

/// Fresh signed trust evidence accepted at a routing floor.
#[derive(Clone, Debug)]
pub struct ChallengeTrust {
    /// Established level after external trust is considered.
    pub level: TrustLevel,
    /// Registered transport key re-bound by the live response.
    pub x25519_public_key: X25519PublicKey,
    /// Canonical current status was covered by the SE key.
    pub status_fields_bound: bool,
}

/// Verifies nonce, challenge signature, canonical status, posture, and floor.
pub fn verify_challenge(
    registration: &RegistrationTrust,
    expected: &ChallengeExpectation,
    response: &AttestationResponse,
    established_level: TrustLevel,
    floor: TrustFloor,
) -> Result<ChallengeTrust, ChallengeVerificationError> {
    if response.nonce != expected.nonce.as_ref() {
        return Err(ChallengeVerificationError::NonceMismatch);
    }
    let echoed_key = X25519PublicKey::from_base64(&response.public_key)
        .map_err(|_| ChallengeVerificationError::InvalidX25519Key)?;
    if !echoed_key.ct_eq(&registration.x25519_public_key) {
        return Err(ChallengeVerificationError::X25519BindingMismatch);
    }

    let mut challenge_data = Vec::with_capacity(
        expected
            .nonce
            .len()
            .saturating_add(expected.timestamp.len()),
    );
    challenge_data.extend_from_slice(expected.nonce.as_bytes());
    challenge_data.extend_from_slice(expected.timestamp.as_bytes());
    verify_signature(
        &registration.se_public_key,
        &response.signature,
        &challenge_data,
    )
    .map_err(map_challenge_signature)?;

    let canonical = response
        .canonical_status_bytes(&expected.timestamp)
        .map_err(|_| ChallengeVerificationError::CanonicalStatus)?;
    if response.status_signature.is_empty() {
        return Err(ChallengeVerificationError::MissingStatusSignature);
    }
    verify_signature(
        &registration.se_public_key,
        &response.status_signature,
        &canonical,
    )
    .map_err(map_status_signature)?;

    match response.sip_enabled {
        Some(true) => {}
        Some(false) => return Err(ChallengeVerificationError::SipDisabled),
        None => return Err(ChallengeVerificationError::SipMissing),
    }
    match response.secure_boot_enabled {
        Some(true) => {}
        Some(false) => return Err(ChallengeVerificationError::SecureBootDisabled),
        None => return Err(ChallengeVerificationError::SecureBootMissing),
    }
    if response.rdma_disabled.is_none() {
        return Err(ChallengeVerificationError::RdmaMissing);
    }
    if established_level < registration.level {
        return Err(ChallengeVerificationError::TrustRegression);
    }
    if !floor.allows(established_level) {
        return Err(ChallengeVerificationError::BelowTrustFloor {
            required: floor.required(),
            actual: established_level,
        });
    }

    Ok(ChallengeTrust {
        level: established_level,
        x25519_public_key: echoed_key,
        status_fields_bound: true,
    })
}

fn map_challenge_signature(error: RegistrationVerificationError) -> ChallengeVerificationError {
    match error {
        RegistrationVerificationError::InvalidSignature => {
            ChallengeVerificationError::InvalidChallengeSignature
        }
        _ => ChallengeVerificationError::ChallengeSignatureMismatch,
    }
}

fn map_status_signature(error: RegistrationVerificationError) -> ChallengeVerificationError {
    match error {
        RegistrationVerificationError::InvalidSignature => {
            ChallengeVerificationError::InvalidStatusSignature
        }
        _ => ChallengeVerificationError::StatusSignatureMismatch,
    }
}

/// Fresh challenge evidence rejection.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum ChallengeVerificationError {
    /// Response did not consume the exact outstanding challenge.
    #[error("attestation challenge nonce mismatch")]
    NonceMismatch,
    /// Echoed key was malformed.
    #[error("challenge response contains invalid X25519 key")]
    InvalidX25519Key,
    /// Another transport key answered the SE challenge.
    #[error("challenge X25519 key does not match registration")]
    X25519BindingMismatch,
    /// Challenge signature was not canonical base64 DER.
    #[error("invalid challenge P-256 signature")]
    InvalidChallengeSignature,
    /// Challenge signature was made by another key or over other bytes.
    #[error("challenge P-256 signature mismatch")]
    ChallengeSignatureMismatch,
    /// Typed fields could not form the protocol canonical status.
    #[error("cannot construct canonical challenge status")]
    CanonicalStatus,
    /// Current providers must bind status; absence cannot raise trust.
    #[error("canonical status signature is missing")]
    MissingStatusSignature,
    /// Status signature was malformed.
    #[error("invalid canonical status P-256 signature")]
    InvalidStatusSignature,
    /// Signed status differs from the live response.
    #[error("canonical status P-256 signature mismatch")]
    StatusSignatureMismatch,
    /// SIP status must be present.
    #[error("SIP status is missing")]
    SipMissing,
    /// SIP status failed closed.
    #[error("SIP is disabled")]
    SipDisabled,
    /// Secure Boot status must be present.
    #[error("Secure Boot status is missing")]
    SecureBootMissing,
    /// Secure Boot status failed closed.
    #[error("Secure Boot is disabled")]
    SecureBootDisabled,
    /// RDMA policy input must be explicit even when enabled RDMA is allowed.
    #[error("RDMA status is missing")]
    RdmaMissing,
    /// A fresh challenge cannot reduce registration trust.
    #[error("challenge trust level regressed below registration trust")]
    TrustRegression,
    /// Evidence is valid but not strong enough for this route.
    #[error("provider trust {actual:?} is below required floor {required:?}")]
    BelowTrustFloor {
        /// Route's required level.
        required: TrustLevel,
        /// Provider's established level.
        actual: TrustLevel,
    },
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use base64::{Engine, engine::general_purpose::STANDARD};
    use p256::{
        ecdsa::{DerSignature, SigningKey, signature::Signer},
        elliptic_curve::Generate,
    };

    use super::*;
    use crate::trust::verify_registration;

    const X25519: &str = "3p7bfXt9wbTTW2HC7OQ1Nz+DQ8hbeGdNrfx+FG+IK08=";

    fn sign(key: &SigningKey, bytes: &[u8]) -> String {
        let signature: DerSignature = key.sign(bytes);
        STANDARD.encode(signature.as_bytes())
    }

    fn registration(key: &SigningKey) -> RegistrationTrust {
        let public = STANDARD.encode(key.verifying_key().to_sec1_point(false));
        let blob = format!(
            concat!(
                r#"{{"encryptionPublicKey":"{x25519}","publicKey":"{public}","#,
                r#""secureBootEnabled":true,"secureEnclaveAvailable":true,"#,
                r#""sipEnabled":true,"timestamp":"2026-07-11T00:00:00Z"}}"#
            ),
            x25519 = X25519,
            public = public,
        );
        let signed = format!(
            r#"{{"attestation":{blob},"signature":"{}"}}"#,
            sign(key, blob.as_bytes())
        );
        verify_registration(
            signed.as_bytes(),
            X25519PublicKey::from_base64(X25519).expect("x25519"),
        )
        .expect("registration")
    }

    fn response(key: &SigningKey, expected: &ChallengeExpectation) -> AttestationResponse {
        let mut response = AttestationResponse {
            nonce: expected.nonce.to_string(),
            signature: sign(
                key,
                format!("{}{}", expected.nonce, expected.timestamp).as_bytes(),
            ),
            status_signature: String::new(),
            public_key: X25519.to_owned(),
            hypervisor_active: None,
            rdma_disabled: Some(true),
            sip_enabled: Some(true),
            secure_boot_enabled: Some(true),
            binary_hash: "binary".to_owned(),
            active_model_hash: String::new(),
            python_hash: String::new(),
            runtime_hash: String::new(),
            template_hashes: BTreeMap::new(),
            grpc_binary_hash: String::new(),
            model_hashes: BTreeMap::new(),
        };
        response.status_signature = sign(
            key,
            &response
                .canonical_status_bytes(&expected.timestamp)
                .expect("canonical"),
        );
        response
    }

    #[test]
    fn live_challenge_and_status_are_bound_and_tamper_fails() {
        let key = SigningKey::generate();
        let registration = registration(&key);
        let expected = ChallengeExpectation {
            nonce: Arc::from("nonce"),
            timestamp: Arc::from("2026-07-11T01:00:00Z"),
        };
        let response = response(&key, &expected);
        let trust = verify_challenge(
            &registration,
            &expected,
            &response,
            TrustLevel::SelfSigned,
            TrustFloor::SELF_ROUTE,
        )
        .expect("challenge");
        assert!(trust.status_fields_bound);

        let mut tampered = response;
        tampered.binary_hash = "other".to_owned();
        assert_eq!(
            verify_challenge(
                &registration,
                &expected,
                &tampered,
                TrustLevel::SelfSigned,
                TrustFloor::SELF_ROUTE,
            )
            .expect_err("status tamper"),
            ChallengeVerificationError::StatusSignatureMismatch
        );
    }

    #[test]
    fn public_floor_requires_external_hardware_trust() {
        let key = SigningKey::generate();
        let registration = registration(&key);
        let expected = ChallengeExpectation {
            nonce: Arc::from("n"),
            timestamp: Arc::from("t"),
        };
        let response = response(&key, &expected);
        assert!(matches!(
            verify_challenge(
                &registration,
                &expected,
                &response,
                TrustLevel::SelfSigned,
                TrustFloor::PUBLIC,
            ),
            Err(ChallengeVerificationError::BelowTrustFloor { .. })
        ));
    }
}
