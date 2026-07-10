//! Secure Enclave P-256 ECDSA verification, mirroring
//! `coordinator/attestation/attestation.go` byte-for-byte.
//!
//! Digest construction:
//! - Challenge responses sign `SHA-256(nonce + timestamp)` where `nonce` is
//!   the base64 nonce *string* from the challenge and `timestamp` is the ISO
//!   8601 string — plain string concatenation, exactly as
//!   `provider.go verifyChallengeResponse` builds `challengeData`.
//! - Registration attestation blobs sign `SHA-256(raw blob JSON bytes)`; the
//!   raw bytes must come from [`crate::json_v1::RegisterMessage::attestation`]
//!   unmodified (Swift escapes `/` as `\/`, so re-encoding breaks the hash).
//! - Status signatures (v0.3.11+) sign `SHA-256(canonical status JSON)` from
//!   [`build_status_canonical`].
//!
//! Public keys arrive base64-encoded as raw P-256 points: 65 bytes
//! uncompressed (`0x04 || X || Y`) or 64 bytes raw `X || Y` (CryptoKit),
//! matching Go `ParseP256PublicKey`. Signatures are base64 ASN.1 DER.

use std::collections::BTreeMap;

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use p256::ecdsa::signature::Verifier;
use p256::ecdsa::{Signature, VerifyingKey};

/// Verification failures. Never carries payload bytes.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SigningError {
    #[error("invalid public key base64")]
    InvalidPublicKeyEncoding,
    #[error("unsupported public key format: expected 64 or 65 bytes, got {0}")]
    InvalidPublicKeyLength(usize),
    #[error("public key is not a valid P-256 point")]
    InvalidPublicKey,
    #[error("invalid signature base64")]
    InvalidSignatureEncoding,
    #[error("invalid DER signature")]
    InvalidDerSignature,
    #[error("ECDSA signature verification failed")]
    VerificationFailed,
    #[error("status_signature missing — status fields not cryptographically bound")]
    StatusSignatureMissing,
}

/// Parses a raw P-256 public key point: uncompressed (65 bytes,
/// `0x04 || X || Y`) or raw `X || Y` (64 bytes), mirroring Go
/// `ParseP256PublicKey`.
pub fn parse_p256_public_key(raw: &[u8]) -> Result<VerifyingKey, SigningError> {
    let sec1: Vec<u8> = match raw.len() {
        65 if raw[0] == 0x04 => raw.to_vec(),
        64 => {
            let mut v = Vec::with_capacity(65);
            v.push(0x04);
            v.extend_from_slice(raw);
            v
        }
        n => return Err(SigningError::InvalidPublicKeyLength(n)),
    };
    VerifyingKey::from_sec1_bytes(&sec1).map_err(|_| SigningError::InvalidPublicKey)
}

/// Parses a base64-encoded raw P-256 public key.
pub fn parse_p256_public_key_b64(b64: &str) -> Result<VerifyingKey, SigningError> {
    let raw = BASE64
        .decode(b64)
        .map_err(|_| SigningError::InvalidPublicKeyEncoding)?;
    parse_p256_public_key(&raw)
}

/// Verifies a base64 DER ECDSA P-256 signature over `SHA-256(payload)`.
/// The general primitive behind challenge, status, raw-blob, and terminal
/// verification.
pub fn verify_signed_payload(
    se_public_key_b64: &str,
    signature_b64: &str,
    payload: &[u8],
) -> Result<(), SigningError> {
    let key = parse_p256_public_key_b64(se_public_key_b64)?;
    let sig_bytes = BASE64
        .decode(signature_b64)
        .map_err(|_| SigningError::InvalidSignatureEncoding)?;
    let signature =
        Signature::from_der(&sig_bytes).map_err(|_| SigningError::InvalidDerSignature)?;
    key.verify(payload, &signature)
        .map_err(|_| SigningError::VerificationFailed)
}

/// The exact bytes a provider signs for a liveness challenge: the base64
/// nonce string concatenated with the ISO 8601 timestamp string.
pub fn challenge_data(nonce: &str, timestamp: &str) -> String {
    format!("{nonce}{timestamp}")
}

/// Verifies a challenge signature over nonce + timestamp (Go
/// `VerifyChallengeSignature`). `data` is [`challenge_data`] output.
pub fn verify_challenge_signature(
    se_public_key_b64: &str,
    signature_b64: &str,
    data: &str,
) -> Result<(), SigningError> {
    verify_signed_payload(se_public_key_b64, signature_b64, data.as_bytes())
}

/// Fields covered by `status_signature` in the v1 attestation response,
/// mirroring Go `attestation.StatusCanonicalInput`.
///
/// Absent fields are OMITTED from the canonical payload — "unknown" must
/// serialize differently than "false" so a downgrade attacker can't strip a
/// `sip_enabled=true` claim and have it look unreported.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct StatusCanonicalInput {
    pub nonce: String,
    pub timestamp: String,
    /// Legacy fleet compat: providers < v0.6.31 sign `hypervisor_active`.
    /// Carry it through when reported so their signatures keep verifying.
    pub hypervisor_active: Option<bool>,
    pub rdma_disabled: Option<bool>,
    pub sip_enabled: Option<bool>,
    pub secure_boot_enabled: Option<bool>,
    pub binary_hash: String,
    pub active_model_hash: String,
    pub python_hash: String,
    pub runtime_hash: String,
    pub template_hashes: BTreeMap<String, String>,
    pub grpc_binary_hash: String,
    pub model_hashes: BTreeMap<String, String>,
}

/// Serializes the canonical status JSON, byte-for-byte identical to Go
/// `attestation.BuildStatusCanonical`: compact JSON, keys sorted
/// alphabetically, nil/empty fields omitted, no HTML escaping, no trailing
/// newline. (`serde_json` never HTML-escapes and `BTreeMap` sorts keys, so
/// both fall out naturally.)
pub fn build_status_canonical(input: &StatusCanonicalInput) -> Vec<u8> {
    use serde_json::Value;
    let mut m: BTreeMap<&'static str, Value> = BTreeMap::new();
    m.insert("nonce", Value::String(input.nonce.clone()));
    m.insert("timestamp", Value::String(input.timestamp.clone()));
    if let Some(v) = input.hypervisor_active {
        m.insert("hypervisor_active", Value::Bool(v));
    }
    if let Some(v) = input.rdma_disabled {
        m.insert("rdma_disabled", Value::Bool(v));
    }
    if let Some(v) = input.sip_enabled {
        m.insert("sip_enabled", Value::Bool(v));
    }
    if let Some(v) = input.secure_boot_enabled {
        m.insert("secure_boot_enabled", Value::Bool(v));
    }
    if !input.binary_hash.is_empty() {
        m.insert("binary_hash", Value::String(input.binary_hash.clone()));
    }
    if !input.active_model_hash.is_empty() {
        m.insert(
            "active_model_hash",
            Value::String(input.active_model_hash.clone()),
        );
    }
    if !input.python_hash.is_empty() {
        m.insert("python_hash", Value::String(input.python_hash.clone()));
    }
    if !input.runtime_hash.is_empty() {
        m.insert("runtime_hash", Value::String(input.runtime_hash.clone()));
    }
    if !input.template_hashes.is_empty() {
        m.insert("template_hashes", string_map(&input.template_hashes));
    }
    if !input.grpc_binary_hash.is_empty() {
        m.insert(
            "grpc_binary_hash",
            Value::String(input.grpc_binary_hash.clone()),
        );
    }
    if !input.model_hashes.is_empty() {
        m.insert("model_hashes", string_map(&input.model_hashes));
    }
    serde_json::to_vec(&m).expect("canonical status map serialization cannot fail")
}

fn string_map(m: &BTreeMap<String, String>) -> serde_json::Value {
    serde_json::Value::Object(
        m.iter()
            .map(|(k, v)| (k.clone(), serde_json::Value::String(v.clone())))
            .collect(),
    )
}

/// Verifies `status_signature` over [`build_status_canonical`] (Go
/// `VerifyStatusSignature`). An empty signature returns
/// [`SigningError::StatusSignatureMissing`]: callers must treat the status
/// fields as advisory and refuse trust upgrades based on them.
pub fn verify_status_signature(
    se_public_key_b64: &str,
    status_signature_b64: &str,
    input: &StatusCanonicalInput,
) -> Result<(), SigningError> {
    if status_signature_b64.is_empty() {
        return Err(SigningError::StatusSignatureMissing);
    }
    let canonical = build_status_canonical(input);
    verify_signed_payload(se_public_key_b64, status_signature_b64, &canonical)
}

#[cfg(test)]
mod tests {
    use p256::ecdsa::signature::Signer;
    use p256::ecdsa::SigningKey;

    use super::*;

    fn test_key() -> (SigningKey, String) {
        let signing = SigningKey::from_slice(&[0x17; 32]).expect("valid scalar");
        let pub_b64 = BASE64.encode(signing.verifying_key().to_encoded_point(false).as_bytes());
        (signing, pub_b64)
    }

    fn sign_b64(key: &SigningKey, payload: &[u8]) -> String {
        let sig: Signature = key.sign(payload);
        BASE64.encode(sig.to_der().as_bytes())
    }

    #[test]
    fn challenge_signature_round_trip() {
        let (key, pub_b64) = test_key();
        let data = challenge_data("bm9uY2U=", "2026-07-09T12:00:00Z");
        let sig = sign_b64(&key, data.as_bytes());
        verify_challenge_signature(&pub_b64, &sig, &data).unwrap();
        assert_eq!(
            verify_challenge_signature(&pub_b64, &sig, "tampered").unwrap_err(),
            SigningError::VerificationFailed
        );
    }

    #[test]
    fn accepts_64_byte_raw_keys() {
        let (key, _) = test_key();
        let point = key.verifying_key().to_encoded_point(false);
        let raw64 = &point.as_bytes()[1..];
        let pub_b64 = BASE64.encode(raw64);
        let sig = sign_b64(&key, b"payload");
        verify_signed_payload(&pub_b64, &sig, b"payload").unwrap();
    }

    #[test]
    fn rejects_bad_keys_and_signatures() {
        let (key, pub_b64) = test_key();
        let sig = sign_b64(&key, b"p");
        assert_eq!(
            verify_signed_payload("!!!", &sig, b"p").unwrap_err(),
            SigningError::InvalidPublicKeyEncoding
        );
        assert_eq!(
            verify_signed_payload(&BASE64.encode([1u8; 10]), &sig, b"p").unwrap_err(),
            SigningError::InvalidPublicKeyLength(10)
        );
        // A 65-byte key without the 0x04 prefix is a length/format error,
        // mirroring Go's ParseP256PublicKey.
        assert_eq!(
            verify_signed_payload(&BASE64.encode([0xffu8; 65]), &sig, b"p").unwrap_err(),
            SigningError::InvalidPublicKeyLength(65)
        );
        assert_eq!(
            verify_signed_payload(&pub_b64, "%%%", b"p").unwrap_err(),
            SigningError::InvalidSignatureEncoding
        );
        assert_eq!(
            verify_signed_payload(&pub_b64, &BASE64.encode([1u8; 8]), b"p").unwrap_err(),
            SigningError::InvalidDerSignature
        );
    }

    #[test]
    fn canonical_status_omission_rules() {
        let minimal = StatusCanonicalInput {
            nonce: "n".into(),
            timestamp: "t".into(),
            ..Default::default()
        };
        assert_eq!(
            build_status_canonical(&minimal),
            br#"{"nonce":"n","timestamp":"t"}"#
        );

        let with_false = StatusCanonicalInput {
            sip_enabled: Some(false),
            ..minimal.clone()
        };
        // Explicit false survives; None is omitted.
        assert_eq!(
            build_status_canonical(&with_false),
            br#"{"nonce":"n","sip_enabled":false,"timestamp":"t"}"#
        );
    }

    #[test]
    fn status_signature_round_trip_and_missing() {
        let (key, pub_b64) = test_key();
        let input = StatusCanonicalInput {
            nonce: "abc".into(),
            timestamp: "2026-07-09T00:00:00Z".into(),
            hypervisor_active: Some(false),
            sip_enabled: Some(true),
            binary_hash: "bh".into(),
            template_hashes: [("chatml".to_owned(), "aa".to_owned())].into(),
            ..Default::default()
        };
        let sig = sign_b64(&key, &build_status_canonical(&input));
        verify_status_signature(&pub_b64, &sig, &input).unwrap();

        assert_eq!(
            verify_status_signature(&pub_b64, "", &input).unwrap_err(),
            SigningError::StatusSignatureMissing
        );

        // Stripping a signed field must break verification.
        let stripped = StatusCanonicalInput {
            sip_enabled: None,
            ..input
        };
        assert_eq!(
            verify_status_signature(&pub_b64, &sig, &stripped).unwrap_err(),
            SigningError::VerificationFailed
        );
    }
}
