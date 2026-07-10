//! NaCl Box cross-language vectors: Go (`golang.org/x/crypto/nacl/box`)
//! sealed every payload with fixed keys and nonces.
//!
//! Interop proof, both directions, without running Go here:
//! - Go → Rust: Rust opens every Go-sealed payload (full-key and precomputed
//!   shared-key paths).
//! - Rust → Go: with the same key + nonce, Rust's seal must produce the
//!   byte-identical ciphertext Go produced — a deterministic construction —
//!   and the `box.Precompute` shared key must match byte-for-byte, so
//!   anything Rust seals is exactly what Go would have sealed and can open.

mod common;

use darkbloom_protocol::crypto::nacl_box::{
    encode_public_key, open, open_with_shared_key, parse_public_key, precompute_shared_key,
    seal_with_nonce, SecretKey, NONCE_LEN,
};
use darkbloom_protocol::crypto::CryptoError;
use darkbloom_protocol::json_v1::EncryptedPayload;
use serde::Deserialize;

#[derive(Deserialize)]
struct BoxVector {
    name: String,
    sender_private_key_hex: String,
    sender_public_key_b64: String,
    recipient_private_key_hex: String,
    recipient_public_key_b64: String,
    nonce_hex: String,
    plaintext_hex: String,
    payload: EncryptedPayload,
    shared_key_hex: String,
}

fn vectors() -> Vec<BoxVector> {
    serde_json::from_slice(&common::read_vector_file("nacl_box/vectors.json"))
        .expect("nacl_box vectors parse")
}

fn secret_from_hex(s: &str) -> SecretKey {
    SecretKey::from(common::hex32(s))
}

#[test]
fn key_derivation_matches_go() {
    for v in vectors() {
        let sender = secret_from_hex(&v.sender_private_key_hex);
        let recipient = secret_from_hex(&v.recipient_private_key_hex);
        assert_eq!(
            encode_public_key(&sender.public_key()),
            v.sender_public_key_b64,
            "{}: sender public key derivation diverged",
            v.name
        );
        assert_eq!(
            encode_public_key(&recipient.public_key()),
            v.recipient_public_key_b64,
            "{}: recipient public key derivation diverged",
            v.name
        );
    }
}

#[test]
fn rust_opens_every_go_sealed_payload() {
    for v in vectors() {
        let recipient = secret_from_hex(&v.recipient_private_key_hex);
        let plaintext =
            open(&v.payload, &recipient).unwrap_or_else(|e| panic!("{}: open failed: {e}", v.name));
        assert_eq!(plaintext, common::from_hex(&v.plaintext_hex), "{}", v.name);
    }
}

#[test]
fn precomputed_shared_key_matches_go_precompute() {
    for v in vectors() {
        let sender = secret_from_hex(&v.sender_private_key_hex);
        let recipient = secret_from_hex(&v.recipient_private_key_hex);
        let sender_pub = parse_public_key(&v.sender_public_key_b64).unwrap();
        let recipient_pub = parse_public_key(&v.recipient_public_key_b64).unwrap();

        let expected = common::hex32(&v.shared_key_hex);
        // Both derivation directions must equal Go's box.Precompute output.
        assert_eq!(
            precompute_shared_key(&recipient_pub, &sender).as_bytes(),
            &expected,
            "{}: sender-side shared key diverged",
            v.name
        );
        assert_eq!(
            precompute_shared_key(&sender_pub, &recipient).as_bytes(),
            &expected,
            "{}: recipient-side shared key diverged",
            v.name
        );

        // The hot-path symmetric open works with that key.
        let shared = precompute_shared_key(&sender_pub, &recipient);
        assert_eq!(
            open_with_shared_key(&v.payload, &shared).unwrap(),
            common::from_hex(&v.plaintext_hex),
            "{}",
            v.name
        );
    }
}

#[test]
fn rust_seal_is_byte_identical_to_go_seal() {
    for v in vectors() {
        let sender = secret_from_hex(&v.sender_private_key_hex);
        let recipient_pub = parse_public_key(&v.recipient_public_key_b64).unwrap();
        let nonce: [u8; NONCE_LEN] = common::from_hex(&v.nonce_hex)
            .try_into()
            .expect("24-byte nonce");
        let plaintext = common::from_hex(&v.plaintext_hex);

        let sealed = seal_with_nonce(&plaintext, &nonce, &recipient_pub, &sender)
            .unwrap_or_else(|e| panic!("{}: seal failed: {e}", v.name));
        assert_eq!(
            sealed, v.payload,
            "{}: Rust seal is not byte-identical to Go box.Seal",
            v.name
        );
    }
}

#[test]
fn tampered_go_payloads_fail_closed() {
    for v in vectors() {
        let recipient = secret_from_hex(&v.recipient_private_key_hex);
        use base64::engine::general_purpose::STANDARD as BASE64;
        use base64::Engine;
        let mut wire = BASE64.decode(&v.payload.ciphertext).unwrap();
        if wire.len() <= NONCE_LEN {
            continue; // nothing past the nonce to tamper with
        }
        let last = wire.len() - 1;
        wire[last] ^= 0x01;
        let tampered = EncryptedPayload {
            ephemeral_public_key: v.payload.ephemeral_public_key.clone(),
            ciphertext: BASE64.encode(&wire),
        };
        assert_eq!(
            open(&tampered, &recipient).unwrap_err(),
            CryptoError::DecryptionFailed,
            "{}",
            v.name
        );
    }
}
