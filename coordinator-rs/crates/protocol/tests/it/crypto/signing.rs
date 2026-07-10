//! Secure Enclave P-256 signing vectors: a deterministic Go ECDSA key signed
//! (a) challenge nonce+timestamp data, (b) canonical status payloads built by
//! `attestation.BuildStatusCanonical`, and (c) a raw Swift-style attestation
//! blob. Rust must rebuild the canonical bytes byte-identically and verify
//! every signature.

use std::collections::BTreeMap;

use crate::support;
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use darkbloom_protocol::crypto::signing::{
    build_status_canonical, challenge_data, verify_challenge_signature, verify_signed_payload,
    verify_status_signature, SigningError, StatusCanonicalInput,
};
use serde::Deserialize;

#[derive(Deserialize)]
struct Vectors {
    se_public_key_b64: String,
    se_public_key_raw64_b64: String,
    challenge: ChallengeVector,
    status_full: StatusVector,
    status_minimal: StatusVector,
    raw_blob: RawBlobVector,
}

#[derive(Deserialize)]
struct ChallengeVector {
    nonce_b64: String,
    timestamp: String,
    data: String,
    signature_b64: String,
}

#[derive(Deserialize)]
struct StatusVector {
    input: StatusInputJson,
    canonical_b64: String,
    signature_b64: String,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct StatusInputJson {
    nonce: String,
    timestamp: String,
    hypervisor_active: Option<bool>,
    rdma_disabled: Option<bool>,
    sip_enabled: Option<bool>,
    secure_boot_enabled: Option<bool>,
    binary_hash: String,
    active_model_hash: String,
    python_hash: String,
    runtime_hash: String,
    template_hashes: BTreeMap<String, String>,
    grpc_binary_hash: String,
    model_hashes: BTreeMap<String, String>,
}

impl From<StatusInputJson> for StatusCanonicalInput {
    fn from(j: StatusInputJson) -> Self {
        StatusCanonicalInput {
            nonce: j.nonce,
            timestamp: j.timestamp,
            hypervisor_active: j.hypervisor_active,
            rdma_disabled: j.rdma_disabled,
            sip_enabled: j.sip_enabled,
            secure_boot_enabled: j.secure_boot_enabled,
            binary_hash: j.binary_hash,
            active_model_hash: j.active_model_hash,
            python_hash: j.python_hash,
            runtime_hash: j.runtime_hash,
            template_hashes: j.template_hashes,
            grpc_binary_hash: j.grpc_binary_hash,
            model_hashes: j.model_hashes,
        }
    }
}

#[derive(Deserialize)]
struct RawBlobVector {
    blob_b64: String,
    signature_b64: String,
}

fn vectors() -> Vectors {
    serde_json::from_slice(&support::read_vector_file("signing/vectors.json"))
        .expect("signing vectors parse")
}

#[test]
fn challenge_signature_verifies_with_both_key_formats() {
    let v = vectors();
    assert_eq!(
        challenge_data(&v.challenge.nonce_b64, &v.challenge.timestamp),
        v.challenge.data,
        "challenge data is nonce_b64 + timestamp string concatenation"
    );
    // 65-byte uncompressed point.
    verify_challenge_signature(
        &v.se_public_key_b64,
        &v.challenge.signature_b64,
        &v.challenge.data,
    )
    .expect("verify with uncompressed key");
    // 64-byte raw X||Y (CryptoKit shape).
    verify_challenge_signature(
        &v.se_public_key_raw64_b64,
        &v.challenge.signature_b64,
        &v.challenge.data,
    )
    .expect("verify with raw64 key");

    assert_eq!(
        verify_challenge_signature(
            &v.se_public_key_b64,
            &v.challenge.signature_b64,
            "tampered data",
        )
        .unwrap_err(),
        SigningError::VerificationFailed
    );
}

#[test]
fn status_canonical_bytes_match_go_byte_for_byte() {
    let v = vectors();
    for (name, vector) in [("full", v.status_full), ("minimal", v.status_minimal)] {
        let go_canonical = BASE64.decode(&vector.canonical_b64).expect("canonical b64");
        let input: StatusCanonicalInput = vector.input.into();
        let rust_canonical = build_status_canonical(&input);
        assert_eq!(
            rust_canonical,
            go_canonical,
            "{name}: canonical bytes diverged\n  go:   {}\n  rust: {}",
            String::from_utf8_lossy(&go_canonical),
            String::from_utf8_lossy(&rust_canonical),
        );
        verify_status_signature(&v.se_public_key_b64, &vector.signature_b64, &input)
            .unwrap_or_else(|e| panic!("{name}: status signature failed: {e}"));

        // Stripping a signed field (or adding one) must break verification.
        let mut stripped = input.clone();
        stripped.timestamp.push('X');
        assert_eq!(
            verify_status_signature(&v.se_public_key_b64, &vector.signature_b64, &stripped)
                .unwrap_err(),
            SigningError::VerificationFailed,
            "{name}"
        );
    }
}

#[test]
fn empty_status_signature_is_missing_not_invalid() {
    let v = vectors();
    let input: StatusCanonicalInput = v.status_minimal.input.into();
    assert_eq!(
        verify_status_signature(&v.se_public_key_b64, "", &input).unwrap_err(),
        SigningError::StatusSignatureMissing
    );
}

#[test]
fn raw_attestation_blob_signature_verifies_over_exact_bytes() {
    let v = vectors();
    let blob = BASE64.decode(&v.raw_blob.blob_b64).expect("blob b64");
    verify_signed_payload(&v.se_public_key_b64, &v.raw_blob.signature_b64, &blob)
        .expect("raw blob signature");

    // Any re-encode (even semantically identical) must fail: the Swift-style
    // `\/` escape means normalized bytes differ from signed bytes.
    let normalized = serde_json::to_vec(
        &serde_json::from_slice::<serde_json::Value>(&blob).expect("blob is valid JSON"),
    )
    .expect("normalize");
    assert_ne!(
        normalized, blob,
        "fixture must exercise non-normal encoding"
    );
    assert_eq!(
        verify_signed_payload(&v.se_public_key_b64, &v.raw_blob.signature_b64, &normalized)
            .unwrap_err(),
        SigningError::VerificationFailed,
        "re-encoded blob must not verify — always hash the original bytes"
    );
}
