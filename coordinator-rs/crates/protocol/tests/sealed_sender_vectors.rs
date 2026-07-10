//! Sealed-sender transport vectors: Go (`nacl/box`, mirroring
//! `coordinator/api/sender_encryption.go`) produced a sealed request
//! envelope, a sealed response envelope, and a sealed SSE line with fixed
//! keys and nonces. Rust must open all three and reproduce them
//! byte-identically with the same nonces.

mod common;

use darkbloom_protocol::crypto::nacl_box::{parse_public_key, SecretKey, NONCE_LEN};
use darkbloom_protocol::crypto::sealed_sender::{
    derive_kid, open_request, open_response, open_sse_line, seal_request_with_nonce,
    seal_response_with_nonce, seal_sse_event_with_nonce, SealedRequestEnvelope,
    SealedResponseEnvelope,
};
use darkbloom_protocol::crypto::CryptoError;
use serde::Deserialize;

#[derive(Deserialize)]
struct Vectors {
    coordinator_private_key_hex: String,
    coordinator_public_key_b64: String,
    kid: String,
    client_private_key_hex: String,
    client_public_key_b64: String,
    request: RequestVector,
    response: ResponseVector,
    sse: SseVector,
}

#[derive(Deserialize)]
struct RequestVector {
    plaintext_hex: String,
    nonce_hex: String,
    envelope: SealedRequestEnvelope,
}

#[derive(Deserialize)]
struct ResponseVector {
    plaintext_hex: String,
    nonce_hex: String,
    envelope: SealedResponseEnvelope,
}

#[derive(Deserialize)]
struct SseVector {
    event_hex: String,
    nonce_hex: String,
    line: String,
}

fn vectors() -> Vectors {
    serde_json::from_slice(&common::read_vector_file("sealed_sender/vectors.json"))
        .expect("sealed_sender vectors parse")
}

fn nonce(hex: &str) -> [u8; NONCE_LEN] {
    common::from_hex(hex).try_into().expect("24-byte nonce")
}

#[test]
fn kid_derivation_matches_go() {
    let v = vectors();
    let coord_pub = parse_public_key(&v.coordinator_public_key_b64).unwrap();
    assert_eq!(derive_kid(&coord_pub), v.kid);
}

#[test]
fn coordinator_opens_go_sealed_request_and_reseals_identically() {
    let v = vectors();
    let coord_secret = SecretKey::from(common::hex32(&v.coordinator_private_key_hex));
    let coord_pub = parse_public_key(&v.coordinator_public_key_b64).unwrap();
    let client_secret = SecretKey::from(common::hex32(&v.client_private_key_hex));

    let (plaintext, sender_pub) =
        open_request(&v.request.envelope, &coord_secret, &v.kid).expect("open request");
    assert_eq!(plaintext, common::from_hex(&v.request.plaintext_hex));
    assert_eq!(
        sender_pub.as_bytes(),
        parse_public_key(&v.client_public_key_b64)
            .unwrap()
            .as_bytes()
    );

    // Deterministic client-side re-seal must reproduce the Go envelope.
    let resealed = seal_request_with_nonce(
        &plaintext,
        &nonce(&v.request.nonce_hex),
        &coord_pub,
        &v.kid,
        &client_secret,
    )
    .expect("re-seal request");
    assert_eq!(resealed, v.request.envelope);
}

#[test]
fn client_opens_go_sealed_response_and_coordinator_reseals_identically() {
    let v = vectors();
    let coord_secret = SecretKey::from(common::hex32(&v.coordinator_private_key_hex));
    let coord_pub = parse_public_key(&v.coordinator_public_key_b64).unwrap();
    let client_secret = SecretKey::from(common::hex32(&v.client_private_key_hex));
    let client_pub = parse_public_key(&v.client_public_key_b64).unwrap();

    let plaintext =
        open_response(&v.response.envelope, &coord_pub, &client_secret, &v.kid).expect("open");
    assert_eq!(plaintext, common::from_hex(&v.response.plaintext_hex));

    let resealed = seal_response_with_nonce(
        &plaintext,
        &nonce(&v.response.nonce_hex),
        &client_pub,
        &coord_secret,
        &v.kid,
    )
    .expect("re-seal response");
    assert_eq!(resealed, v.response.envelope);
}

#[test]
fn sse_line_round_trips_byte_identically() {
    let v = vectors();
    let coord_secret = SecretKey::from(common::hex32(&v.coordinator_private_key_hex));
    let coord_pub = parse_public_key(&v.coordinator_public_key_b64).unwrap();
    let client_secret = SecretKey::from(common::hex32(&v.client_private_key_hex));
    let client_pub = parse_public_key(&v.client_public_key_b64).unwrap();

    let event = open_sse_line(&v.sse.line, &coord_pub, &client_secret).expect("open sse");
    assert_eq!(event, common::from_hex(&v.sse.event_hex));

    let resealed =
        seal_sse_event_with_nonce(&event, &nonce(&v.sse.nonce_hex), &client_pub, &coord_secret)
            .expect("re-seal sse");
    assert_eq!(resealed, v.sse.line);
}

#[test]
fn kid_mismatch_and_tamper_fail_closed() {
    let v = vectors();
    let coord_secret = SecretKey::from(common::hex32(&v.coordinator_private_key_hex));

    let mut wrong_kid = v.request.envelope.clone();
    wrong_kid.kid = "0000000000000000".into();
    assert!(matches!(
        open_request(&wrong_kid, &coord_secret, &v.kid).unwrap_err(),
        CryptoError::KidMismatch { .. }
    ));

    // Empty kid skips the check, mirroring the Go middleware.
    let mut empty_kid = v.request.envelope.clone();
    empty_kid.kid = String::new();
    assert!(open_request(&empty_kid, &coord_secret, &v.kid).is_ok());

    use base64::engine::general_purpose::STANDARD as BASE64;
    use base64::Engine;
    let mut wire = BASE64.decode(&v.request.envelope.ciphertext).unwrap();
    let last = wire.len() - 1;
    wire[last] ^= 0x01;
    let mut tampered = v.request.envelope.clone();
    tampered.ciphertext = BASE64.encode(&wire);
    assert_eq!(
        open_request(&tampered, &coord_secret, &v.kid).unwrap_err(),
        CryptoError::DecryptionFailed
    );
}
