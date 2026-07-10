//! Test-only signing fixtures shared by the registration and challenge
//! verification tests (compiled under `cfg(test)` only).

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use p256::ecdsa::signature::Signer;
use p256::ecdsa::{Signature, SigningKey};

use darkbloom_protocol::crypto::signing::{self, StatusCanonicalInput};
use darkbloom_protocol::json_v1::AttestationResponseMessage;

pub(super) fn se_key() -> (SigningKey, String) {
    let key = SigningKey::from_slice(&[0x42; 32]).expect("valid scalar");
    let pub_b64 = BASE64.encode(key.verifying_key().to_encoded_point(false).as_bytes());
    (key, pub_b64)
}

pub(super) fn sign_b64(key: &SigningKey, payload: &[u8]) -> String {
    let sig: Signature = key.sign(payload);
    BASE64.encode(sig.to_der().as_bytes())
}

/// Builds a signed attestation exactly as a Swift provider would: the
/// blob JSON is signed byte-for-byte as embedded.
pub(super) fn signed_attestation(key: &SigningKey, pub_b64: &str, x25519_b64: &str) -> String {
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

pub(super) fn challenge_response(
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
