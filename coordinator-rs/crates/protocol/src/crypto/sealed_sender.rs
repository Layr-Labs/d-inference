//! Consumer → coordinator sealed-transport envelope, mirroring
//! `coordinator/api/sender_encryption.go` exactly.
//!
//! Senders fetch the coordinator's long-lived X25519 public key (plus a short
//! `kid`) from `GET /v1/encryption-key`, NaCl-Box-seal their request body to
//! it, and POST as `Content-Type: application/eigeninference-sealed+json`.
//!
//! Wire shapes:
//! - Request: `{"kid", "ephemeral_public_key", "ciphertext"}` where
//!   `ciphertext` is base64 of `24-byte nonce || box(body)` sealed with
//!   (coordinator public, sender ephemeral secret).
//! - Non-streaming response: `{"kid", "ciphertext"}` sealed with (sender
//!   ephemeral public, coordinator secret).
//! - SSE: each event is one line `data: <base64(nonce || box(event))>\n\n`
//!   where the inner bytes are the original SSE event payload (everything
//!   between `\n\n` boundaries, including any leading `data: ` prefix the
//!   upstream emitted).
//!
//! The `kid` is the first 16 hex chars of SHA-256(public key)
//! (`coordinator/internal/e2e/coordinator_key.go`); [`derive_kid`] mirrors
//! that. A request with an empty `kid` skips the mismatch check, exactly
//! like the Go middleware.

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::nacl_box::{
    encode_public_key, open_bytes, parse_public_key, seal_bytes, PublicKey, SecretKey, NONCE_LEN,
};
use super::CryptoError;

/// Media type senders set on encrypted requests (and the coordinator sets on
/// sealed non-streaming responses).
pub const SEALED_CONTENT_TYPE: &str = "application/eigeninference-sealed+json";

/// On-the-wire shape of a sealed request body (Go `sealedRequestEnvelope`).
/// No field is omitted: Go declares all three without `omitempty`.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct SealedRequestEnvelope {
    pub kid: String,
    pub ephemeral_public_key: String,
    pub ciphertext: String,
}

/// On-the-wire shape of a non-streaming sealed response (Go
/// `sealedResponseEnvelope`).
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct SealedResponseEnvelope {
    pub kid: String,
    pub ciphertext: String,
}

/// Derives the key id senders use to detect rotation: first 16 hex chars of
/// SHA-256(public key).
pub fn derive_kid(public_key: &PublicKey) -> String {
    let sum = Sha256::digest(public_key.as_bytes());
    hex::encode(&sum[..8])
}

/// Seals a request body to the coordinator (client side). The caller supplies
/// its per-request ephemeral secret so it can open the sealed response.
pub fn seal_request(
    body: &[u8],
    coordinator_public: &PublicKey,
    kid: &str,
    ephemeral_secret: &SecretKey,
) -> Result<SealedRequestEnvelope, CryptoError> {
    let mut nonce = [0u8; NONCE_LEN];
    rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut nonce);
    seal_request_with_nonce(body, &nonce, coordinator_public, kid, ephemeral_secret)
}

/// Deterministic [`seal_request`] for fixed-vector tests.
pub fn seal_request_with_nonce(
    body: &[u8],
    nonce: &[u8; NONCE_LEN],
    coordinator_public: &PublicKey,
    kid: &str,
    ephemeral_secret: &SecretKey,
) -> Result<SealedRequestEnvelope, CryptoError> {
    let wire = seal_bytes(body, nonce, coordinator_public, ephemeral_secret)?;
    Ok(SealedRequestEnvelope {
        kid: kid.to_owned(),
        ephemeral_public_key: encode_public_key(&ephemeral_secret.public_key()),
        ciphertext: BASE64.encode(wire),
    })
}

/// Opens a sealed request (coordinator side), returning the plaintext body
/// and the sender's ephemeral public key (needed to seal the response).
///
/// Mirrors the Go middleware: a non-empty envelope `kid` must match
/// `expected_kid`; an empty `kid` skips the check.
pub fn open_request(
    envelope: &SealedRequestEnvelope,
    coordinator_secret: &SecretKey,
    expected_kid: &str,
) -> Result<(Vec<u8>, PublicKey), CryptoError> {
    if !envelope.kid.is_empty() && envelope.kid != expected_kid {
        return Err(CryptoError::KidMismatch {
            got: envelope.kid.clone(),
            expected: expected_kid.to_owned(),
        });
    }
    let sender_public = parse_public_key(&envelope.ephemeral_public_key)?;
    let wire = BASE64
        .decode(&envelope.ciphertext)
        .map_err(|_| CryptoError::InvalidCiphertextEncoding)?;
    let plaintext = open_bytes(&wire, &sender_public, coordinator_secret)?;
    Ok((plaintext, sender_public))
}

/// Seals a buffered (non-streaming) response to the sender (coordinator
/// side), mirroring the Go `sealingResponseWriter` buffered mode.
pub fn seal_response(
    body: &[u8],
    client_public: &PublicKey,
    coordinator_secret: &SecretKey,
    kid: &str,
) -> Result<SealedResponseEnvelope, CryptoError> {
    let mut nonce = [0u8; NONCE_LEN];
    rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut nonce);
    seal_response_with_nonce(body, &nonce, client_public, coordinator_secret, kid)
}

/// Deterministic [`seal_response`] for fixed-vector tests.
pub fn seal_response_with_nonce(
    body: &[u8],
    nonce: &[u8; NONCE_LEN],
    client_public: &PublicKey,
    coordinator_secret: &SecretKey,
    kid: &str,
) -> Result<SealedResponseEnvelope, CryptoError> {
    let wire = seal_bytes(body, nonce, client_public, coordinator_secret)?;
    Ok(SealedResponseEnvelope {
        kid: kid.to_owned(),
        ciphertext: BASE64.encode(wire),
    })
}

/// Opens a sealed response (client side) with the ephemeral secret used for
/// the request. A non-empty envelope `kid` must match `expected_kid`.
pub fn open_response(
    envelope: &SealedResponseEnvelope,
    coordinator_public: &PublicKey,
    ephemeral_secret: &SecretKey,
    expected_kid: &str,
) -> Result<Vec<u8>, CryptoError> {
    if !envelope.kid.is_empty() && envelope.kid != expected_kid {
        return Err(CryptoError::KidMismatch {
            got: envelope.kid.clone(),
            expected: expected_kid.to_owned(),
        });
    }
    let wire = BASE64
        .decode(&envelope.ciphertext)
        .map_err(|_| CryptoError::InvalidCiphertextEncoding)?;
    open_bytes(&wire, coordinator_public, ephemeral_secret)
}

/// Seals one SSE event payload (everything between `\n\n` boundaries,
/// including any upstream `data: ` prefix) into the on-wire line
/// `data: <base64(nonce || sealed)>\n\n` (coordinator side).
pub fn seal_sse_event(
    event: &[u8],
    client_public: &PublicKey,
    coordinator_secret: &SecretKey,
) -> Result<String, CryptoError> {
    let mut nonce = [0u8; NONCE_LEN];
    rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut nonce);
    seal_sse_event_with_nonce(event, &nonce, client_public, coordinator_secret)
}

/// Deterministic [`seal_sse_event`] for fixed-vector tests.
pub fn seal_sse_event_with_nonce(
    event: &[u8],
    nonce: &[u8; NONCE_LEN],
    client_public: &PublicKey,
    coordinator_secret: &SecretKey,
) -> Result<String, CryptoError> {
    let wire = seal_bytes(event, nonce, client_public, coordinator_secret)?;
    Ok(format!("data: {}\n\n", BASE64.encode(wire)))
}

/// Opens one sealed SSE line (client side): strips the `data: ` prefix and
/// event terminator, base64-decodes, peels the nonce, and opens the box.
/// Returns the original upstream event bytes.
pub fn open_sse_line(
    line: &str,
    coordinator_public: &PublicKey,
    ephemeral_secret: &SecretKey,
) -> Result<Vec<u8>, CryptoError> {
    let payload = line
        .trim_end_matches(['\n', '\r'])
        .strip_prefix("data: ")
        .ok_or(CryptoError::MalformedSseLine)?;
    let wire = BASE64
        .decode(payload)
        .map_err(|_| CryptoError::InvalidCiphertextEncoding)?;
    open_bytes(&wire, coordinator_public, ephemeral_secret)
}

#[cfg(test)]
mod tests {
    use super::super::nacl_box;
    use super::*;

    fn keys() -> (PublicKey, SecretKey, PublicKey, SecretKey, String) {
        let (coord_pub, coord_secret) = nacl_box::generate_keypair();
        let (client_pub, client_secret) = nacl_box::generate_keypair();
        let kid = derive_kid(&coord_pub);
        (coord_pub, coord_secret, client_pub, client_secret, kid)
    }

    #[test]
    fn kid_is_16_hex_chars() {
        let (coord_pub, ..) = keys();
        let kid = derive_kid(&coord_pub);
        assert_eq!(kid.len(), 16);
        assert!(kid.bytes().all(|b| b.is_ascii_hexdigit()));
    }

    #[test]
    fn request_response_round_trip() {
        let (coord_pub, coord_secret, _client_pub, client_secret, kid) = keys();
        let body = br#"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#;

        let env = seal_request(body, &coord_pub, &kid, &client_secret).unwrap();
        let (plaintext, sender_pub) = open_request(&env, &coord_secret, &kid).unwrap();
        assert_eq!(plaintext, body);
        assert_eq!(sender_pub.as_bytes(), client_secret.public_key().as_bytes());

        let response = br#"{"choices":[]}"#;
        let renv = seal_response(response, &sender_pub, &coord_secret, &kid).unwrap();
        assert_eq!(renv.kid, kid);
        let opened = open_response(&renv, &coord_pub, &client_secret, &kid).unwrap();
        assert_eq!(opened, response);
    }

    #[test]
    fn kid_mismatch_rejected_but_empty_kid_allowed() {
        let (coord_pub, coord_secret, _, client_secret, kid) = keys();
        let mut env = seal_request(b"x", &coord_pub, &kid, &client_secret).unwrap();

        env.kid = "deadbeefdeadbeef".into();
        match open_request(&env, &coord_secret, &kid).unwrap_err() {
            CryptoError::KidMismatch { got, expected } => {
                assert_eq!(got, "deadbeefdeadbeef");
                assert_eq!(expected, kid);
            }
            other => panic!("expected KidMismatch, got {other:?}"),
        }

        env.kid = String::new();
        assert!(open_request(&env, &coord_secret, &kid).is_ok());
    }

    #[test]
    fn sse_round_trip_including_upstream_prefix() {
        let (coord_pub, coord_secret, client_pub, client_secret, _) = keys();
        let event = b"data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}";
        let line = seal_sse_event(event, &client_pub, &coord_secret).unwrap();
        assert!(line.starts_with("data: ") && line.ends_with("\n\n"));
        let opened = open_sse_line(&line, &coord_pub, &client_secret).unwrap();
        assert_eq!(opened, event);

        assert_eq!(
            open_sse_line("event: x\n\n", &coord_pub, &client_secret).unwrap_err(),
            CryptoError::MalformedSseLine
        );
    }
}
