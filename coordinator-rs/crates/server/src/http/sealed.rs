//! Sender-sealed transport (plan §23.2; Go `sender_encryption.go`).
//!
//! Requests with `Content-Type: application/eigeninference-sealed+json` are
//! NaCl-Box sealed to the coordinator key; the reply is sealed back to the
//! sender's ephemeral key — a sealed envelope for non-streaming, one sealed
//! `data: <base64(nonce || box)>\n\n` line per SSE event for streaming.

use axum::http::HeaderMap;
use bytes::Bytes;

use darkbloom_protocol::crypto::nacl_box::PublicKey;
use darkbloom_protocol::crypto::sealed_sender::{self, SealedRequestEnvelope, SEALED_CONTENT_TYPE};

use crate::contracts::CoordinatorKeys;
use crate::http::errors::ApiError;

/// Whether the request opted into sealed transport (media-type match,
/// parameters ignored — Go `isSealedContentType`).
pub fn is_sealed(headers: &HeaderMap) -> bool {
    headers
        .get(axum::http::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(|v| {
            v.split(';')
                .next()
                .unwrap_or("")
                .trim()
                .eq_ignore_ascii_case(SEALED_CONTENT_TYPE)
        })
        .unwrap_or(false)
}

/// Reply-side sealing context captured from an opened request.
pub struct SealedReply {
    pub sender_public: PublicKey,
    pub kid: String,
}

/// Opens a sealed request body, returning the plaintext and the reply
/// context. Mirrors the Go middleware: a non-empty envelope `kid` must
/// match the coordinator's, an empty `kid` skips the check.
pub fn open_request(keys: &CoordinatorKeys, body: &[u8]) -> Result<(Bytes, SealedReply), ApiError> {
    let envelope: SealedRequestEnvelope =
        serde_json::from_slice(body).map_err(|_| ApiError::SealedRequestInvalid)?;
    let kid = sealed_sender::derive_kid(&keys.x25519_secret.public_key());
    let (plaintext, sender_public) =
        sealed_sender::open_request(&envelope, &keys.x25519_secret, &kid)
            .map_err(|_| ApiError::SealedRequestInvalid)?;
    Ok((Bytes::from(plaintext), SealedReply { sender_public, kid }))
}

/// Seals a buffered (non-streaming) response body.
pub fn seal_response(
    keys: &CoordinatorKeys,
    reply: &SealedReply,
    body: &[u8],
) -> Result<Vec<u8>, ApiError> {
    let envelope =
        sealed_sender::seal_response(body, &reply.sender_public, &keys.x25519_secret, &reply.kid)
            .map_err(|_| ApiError::Internal("failed to seal response"))?;
    serde_json::to_vec(&envelope).map_err(|_| ApiError::Internal("failed to seal response"))
}

/// Seals one SSE event (the full upstream event bytes, including its
/// `data: ` prefix) into a complete on-wire line.
pub fn seal_sse_event(keys: &CoordinatorKeys, reply: &SealedReply, event: &[u8]) -> Option<String> {
    sealed_sender::seal_sse_event(event, &reply.sender_public, &keys.x25519_secret).ok()
}
