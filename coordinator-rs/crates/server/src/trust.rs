//! Pilot-scope trust verifier (plan §7.6).
//!
//! Verifies, on the blocking pool ([`tokio::task::spawn_blocking`] — P-256
//! and JSON canonicalization work must never run inside `FleetActor` or a
//! session read loop):
//!
//! - the registration attestation blob signature over the **raw preserved
//!   bytes** (plan §15.3: never deserialize and reserialize signed input
//!   before hashing — Swift escapes `/` as `\/`, so re-encoding breaks the
//!   digest);
//! - challenge nonce + timestamp signatures
//!   ([`signing::verify_challenge_signature`]);
//! - the canonical status signature ([`signing::verify_status_signature`]).
//!
//! # Pilot scope (explicit)
//!
//! `hardware` trust reuse and the MDM / MDA / APNs verification pillars are
//! **out of scope** for the pilot. The seam is a verdict enum
//! ([`TrustVerdict`]) with [`TrustVerdict::HardwareTrusted`] already present,
//! so those verifiers slot in later by emitting a higher verdict through the
//! same epoch-fenced path; nothing here needs to change shape. The highest
//! verdict this module ever emits is [`TrustVerdict::SelfSigned`] (a valid
//! Secure Enclave attestation with the minimum security posture).
//!
//! # Epoch fencing (plan §9.1.6)
//!
//! Every verification **mints its epoch when the verification starts**, from
//! one process-wide monotonic counter. The fleet applies a verdict only when
//! its epoch is strictly above the provider's current trust epoch, so a hard
//! downgrade issued after a slow verification began can never be reversed
//! when that older verification finally completes.

use std::sync::atomic::{AtomicU64, Ordering};

use serde::Deserialize;

use darkbloom_core::ids::TrustEpoch;
use darkbloom_protocol::crypto::signing::{self, SigningError, StatusCanonicalInput};
use darkbloom_protocol::json_v1::AttestationResponseMessage;

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

/// Process-wide verifier. Holds no key material — it consumes public keys
/// and signatures owned by the caller and returns typed verdicts.
#[derive(Debug, Default)]
pub struct TrustVerifier {
    epoch: AtomicU64,
}

/// Wire shape of the signed registration blob (Go `SignedAttestation`):
/// `attestation` is captured as raw JSON so the exact signed bytes survive.
#[derive(Deserialize)]
struct SignedAttestationWire<'a> {
    #[serde(borrow)]
    attestation: Option<&'a serde_json::value::RawValue>,
    #[serde(default)]
    signature: String,
}

/// Typed view of the blob fields the pilot acts on (Go `AttestationBlob`).
/// Decoded from the same raw bytes AFTER signature verification.
#[derive(Deserialize, Default)]
#[serde(default)]
struct AttestationBlobWire {
    #[serde(rename = "publicKey")]
    public_key: String,
    #[serde(rename = "encryptionPublicKey")]
    encryption_public_key: String,
    #[serde(rename = "serialNumber")]
    serial_number: String,
    #[serde(rename = "secureEnclaveAvailable")]
    secure_enclave_available: bool,
    #[serde(rename = "sipEnabled")]
    sip_enabled: bool,
    #[serde(rename = "secureBootEnabled")]
    secure_boot_enabled: bool,
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

fn untrusted(reason: impl Into<String>) -> TrustVerdict {
    TrustVerdict::Untrusted {
        reason: reason.into(),
    }
}

/// Blocking-pool body of registration verification.
fn verify_registration_blob(
    raw: &str,
    registered_x25519_b64: &str,
) -> (TrustVerdict, Option<String>, Option<String>) {
    let wire: SignedAttestationWire<'_> = match serde_json::from_str(raw) {
        Ok(w) => w,
        Err(_) => return (untrusted("malformed attestation JSON"), None, None),
    };
    let Some(blob_raw) = wire.attestation else {
        return (untrusted("attestation blob missing"), None, None);
    };
    if wire.signature.is_empty() {
        return (untrusted("attestation signature missing"), None, None);
    }
    let blob: AttestationBlobWire = match serde_json::from_str(blob_raw.get()) {
        Ok(b) => b,
        Err(_) => return (untrusted("malformed attestation blob"), None, None),
    };
    if blob.public_key.is_empty() {
        return (untrusted("attestation blob has no public key"), None, None);
    }

    // Signature over SHA-256 of the RAW blob bytes — exactly what the Secure
    // Enclave signed, never a re-encoding.
    if let Err(err) =
        signing::verify_signed_payload(&blob.public_key, &wire.signature, blob_raw.get().as_bytes())
    {
        return (
            untrusted(format!("attestation signature invalid: {err}")),
            None,
            None,
        );
    }

    // Minimum security posture (Go `attestation.Verify` checks 2-4).
    if !blob.secure_enclave_available {
        return (untrusted("Secure Enclave not available"), None, None);
    }
    if !blob.sip_enabled {
        return (untrusted("SIP not enabled"), None, None);
    }
    if !blob.secure_boot_enabled {
        return (untrusted("Secure Boot not enabled"), None, None);
    }

    // Optional binding: the attested encryption key must be the registered
    // X25519 transport key (Go check 5).
    if !blob.encryption_public_key.is_empty()
        && !registered_x25519_b64.is_empty()
        && blob.encryption_public_key != registered_x25519_b64
    {
        return (
            untrusted("attested encryption key does not match registered key"),
            None,
            None,
        );
    }

    let serial = (!blob.serial_number.is_empty()).then(|| blob.serial_number.clone());
    (TrustVerdict::SelfSigned, Some(blob.public_key), serial)
}

/// Blocking-pool body of challenge verification.
fn verify_challenge_response(
    se_public_key_b64: &str,
    registered_x25519_b64: &str,
    expected: &ChallengeExpectation,
    resp: &AttestationResponseMessage,
) -> (TrustVerdict, bool) {
    if resp.nonce != expected.nonce {
        return (untrusted("challenge nonce mismatch"), false);
    }
    // The provider echoes its registered X25519 key; a different key means a
    // different process answered (Go: resp.PublicKey vs provider.PublicKey).
    if !registered_x25519_b64.is_empty()
        && !resp.public_key.is_empty()
        && resp.public_key != registered_x25519_b64
    {
        return (untrusted("challenge public key mismatch"), false);
    }
    if resp.signature.is_empty() {
        return (untrusted("empty challenge signature"), false);
    }
    let data = signing::challenge_data(&expected.nonce, &expected.timestamp);
    if let Err(err) = signing::verify_challenge_signature(se_public_key_b64, &resp.signature, &data)
    {
        return (
            untrusted(format!("challenge signature invalid: {err}")),
            false,
        );
    }

    // Status signature (v0.3.11+). Missing is advisory-only (legacy fleet);
    // a PRESENT-but-wrong signature is tampering and fails hard.
    let status_input = StatusCanonicalInput {
        nonce: expected.nonce.clone(),
        timestamp: expected.timestamp.clone(),
        hypervisor_active: resp.hypervisor_active,
        rdma_disabled: resp.rdma_disabled,
        sip_enabled: resp.sip_enabled,
        secure_boot_enabled: resp.secure_boot_enabled,
        binary_hash: resp.binary_hash.clone(),
        active_model_hash: resp.active_model_hash.clone(),
        python_hash: resp.python_hash.clone(),
        runtime_hash: resp.runtime_hash.clone(),
        template_hashes: resp.template_hashes.clone(),
        grpc_binary_hash: String::new(),
        model_hashes: resp.model_hashes.clone(),
    };
    let status_fields_bound = match signing::verify_status_signature(
        se_public_key_b64,
        &resp.status_signature,
        &status_input,
    ) {
        Ok(()) => true,
        Err(SigningError::StatusSignatureMissing) => false,
        Err(err) => {
            return (untrusted(format!("status signature invalid: {err}")), false);
        }
    };

    // Fresh posture checks (Go: negatives always deroute; omitted mandatory
    // signals fail closed).
    match resp.sip_enabled {
        None => return (untrusted("SIP status not reported"), status_fields_bound),
        Some(false) => return (untrusted("SIP disabled"), status_fields_bound),
        Some(true) => {}
    }
    if resp.secure_boot_enabled == Some(false) {
        return (untrusted("Secure Boot disabled"), status_fields_bound);
    }
    if resp.rdma_disabled.is_none() {
        return (untrusted("RDMA status not reported"), status_fields_bound);
    }
    // RDMA *enabled* is accepted under the registered-buffer RDMA policy.

    (TrustVerdict::SelfSigned, status_fields_bound)
}

#[cfg(test)]
mod tests {
    use base64::engine::general_purpose::STANDARD as BASE64;
    use base64::Engine;
    use p256::ecdsa::signature::Signer;
    use p256::ecdsa::{Signature, SigningKey};

    use super::*;

    fn se_key() -> (SigningKey, String) {
        let key = SigningKey::from_slice(&[0x42; 32]).expect("valid scalar");
        let pub_b64 = BASE64.encode(key.verifying_key().to_encoded_point(false).as_bytes());
        (key, pub_b64)
    }

    fn sign_b64(key: &SigningKey, payload: &[u8]) -> String {
        let sig: Signature = key.sign(payload);
        BASE64.encode(sig.to_der().as_bytes())
    }

    /// Builds a signed attestation exactly as a Swift provider would: the
    /// blob JSON is signed byte-for-byte as embedded.
    fn signed_attestation(key: &SigningKey, pub_b64: &str, x25519_b64: &str) -> String {
        let blob = format!(
            concat!(
                r#"{{"encryptionPublicKey":"{x}","publicKey":"{p}","#,
                r#""secureBootEnabled":true,"secureEnclaveAvailable":true,"#,
                r#""serialNumber":"SER-1","sipEnabled":true,"#,
                r#""timestamp":"2026-07-09T00:00:00Z"}}"#
            ),
            x = x25519_b64,
            p = pub_b64,
        );
        let sig = sign_b64(key, blob.as_bytes());
        format!(r#"{{"attestation":{blob},"signature":"{sig}"}}"#)
    }

    #[tokio::test]
    async fn registration_round_trip_and_tamper() {
        let (key, pub_b64) = se_key();
        let v = TrustVerifier::new();
        let blob = signed_attestation(&key, &pub_b64, "x25519-key");

        let ok = v
            .verify_registration(Some(blob.clone()), "x25519-key".to_owned())
            .await;
        assert!(matches!(ok.verdict, TrustVerdict::SelfSigned));
        assert_eq!(ok.se_public_key.as_deref(), Some(pub_b64.as_str()));
        assert_eq!(ok.serial_number.as_deref(), Some("SER-1"));

        // Any byte flip in the signed blob must fail.
        let tampered = blob.replace("SER-1", "SER-2");
        let bad = v
            .verify_registration(Some(tampered), "x25519-key".to_owned())
            .await;
        assert!(matches!(bad.verdict, TrustVerdict::Untrusted { .. }));

        // Encryption-key binding mismatch must fail.
        let mismatch = v
            .verify_registration(Some(blob), "different-key".to_owned())
            .await;
        assert!(matches!(mismatch.verdict, TrustVerdict::Untrusted { .. }));
    }

    #[tokio::test]
    async fn registration_minimum_posture_enforced() {
        let (key, pub_b64) = se_key();
        let blob = format!(
            concat!(
                r#"{{"publicKey":"{p}","secureBootEnabled":true,"#,
                r#""secureEnclaveAvailable":true,"sipEnabled":false,"#,
                r#""timestamp":"2026-07-09T00:00:00Z"}}"#
            ),
            p = pub_b64,
        );
        let sig = sign_b64(&key, blob.as_bytes());
        let signed = format!(r#"{{"attestation":{blob},"signature":"{sig}"}}"#);
        let out = TrustVerifier::new()
            .verify_registration(Some(signed), String::new())
            .await;
        match out.verdict {
            TrustVerdict::Untrusted { reason } => assert!(reason.contains("SIP")),
            other => panic!("expected untrusted, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn missing_attestation_is_a_verdict() {
        let out = TrustVerifier::new()
            .verify_registration(None, String::new())
            .await;
        assert!(matches!(out.verdict, TrustVerdict::Untrusted { .. }));
        assert!(out.trust_epoch.get() > 0);
    }

    fn challenge_response(
        key: &SigningKey,
        nonce: &str,
        timestamp: &str,
    ) -> AttestationResponseMessage {
        let sig = sign_b64(key, signing::challenge_data(nonce, timestamp).as_bytes());
        let input = StatusCanonicalInput {
            nonce: nonce.to_owned(),
            timestamp: timestamp.to_owned(),
            rdma_disabled: Some(true),
            sip_enabled: Some(true),
            secure_boot_enabled: Some(true),
            ..Default::default()
        };
        let status_sig = sign_b64(key, &signing::build_status_canonical(&input));
        AttestationResponseMessage {
            nonce: nonce.to_owned(),
            signature: sig,
            status_signature: status_sig,
            public_key: "x25519-key".to_owned(),
            rdma_disabled: Some(true),
            sip_enabled: Some(true),
            secure_boot_enabled: Some(true),
            ..Default::default()
        }
    }

    #[tokio::test]
    async fn challenge_round_trip_and_downgrades() {
        let (key, se_pub) = se_key();
        let v = TrustVerifier::new();
        let expected = ChallengeExpectation {
            nonce: "bm9uY2U=".to_owned(),
            timestamp: "2026-07-09T12:00:00Z".to_owned(),
        };
        let resp = challenge_response(&key, &expected.nonce, &expected.timestamp);

        let ok = v
            .verify_challenge(
                se_pub.clone(),
                "x25519-key".to_owned(),
                expected.clone(),
                resp.clone(),
            )
            .await;
        assert!(matches!(ok.verdict, TrustVerdict::SelfSigned));
        assert!(ok.status_fields_bound);

        // SIP=false always deroutes even when correctly signed.
        let mut sip_off = resp.clone();
        sip_off.sip_enabled = Some(false);
        let input = StatusCanonicalInput {
            nonce: expected.nonce.clone(),
            timestamp: expected.timestamp.clone(),
            rdma_disabled: Some(true),
            sip_enabled: Some(false),
            secure_boot_enabled: Some(true),
            ..Default::default()
        };
        sip_off.status_signature = sign_b64(&key, &signing::build_status_canonical(&input));
        let out = v
            .verify_challenge(
                se_pub.clone(),
                "x25519-key".to_owned(),
                expected.clone(),
                sip_off,
            )
            .await;
        assert!(matches!(out.verdict, TrustVerdict::Untrusted { .. }));

        // Nonce mismatch fails before any crypto.
        let mut wrong_nonce = resp.clone();
        wrong_nonce.nonce = "other".to_owned();
        let out = v
            .verify_challenge(
                se_pub.clone(),
                "x25519-key".to_owned(),
                expected.clone(),
                wrong_nonce,
            )
            .await;
        assert!(matches!(out.verdict, TrustVerdict::Untrusted { .. }));

        // A present-but-wrong status signature is tampering.
        let mut bad_status = resp;
        bad_status.binary_hash = "spoofed".to_owned();
        let out = v
            .verify_challenge(se_pub, "x25519-key".to_owned(), expected, bad_status)
            .await;
        assert!(matches!(out.verdict, TrustVerdict::Untrusted { .. }));
    }

    #[test]
    fn epochs_are_strictly_monotonic() {
        let v = TrustVerifier::new();
        let a = v.next_epoch();
        let b = v.next_epoch();
        assert!(b > a);
    }
}
