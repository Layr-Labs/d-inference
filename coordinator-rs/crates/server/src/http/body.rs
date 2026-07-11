use axum::{
    body::{Body, to_bytes},
    http::{HeaderMap, StatusCode, header},
};
use darkbloom_coordinator_protocol::crypto::SenderSealEnvelope;
use tokio::sync::OwnedSemaphorePermit;

use crate::{
    crypto::X25519PublicKey,
    pilot::{INPUT_RESERVATION_BYTES, MAX_CONSUMER_BODY_BYTES, PilotHandle, PilotResourceError},
};

use super::error::ApiError;

pub const SEALED_CONTENT_TYPE: &str = "application/eigeninference-sealed+json";

pub struct ConsumerInput {
    pub plaintext: Vec<u8>,
    pub sender: Option<X25519PublicKey>,
    pub input_permit: OwnedSemaphorePermit,
}

pub async fn read_consumer_input(
    headers: &HeaderMap,
    body: Body,
    pilot: &PilotHandle,
) -> Result<ConsumerInput, ApiError> {
    let input_permit = pilot
        .try_reserve_input(INPUT_RESERVATION_BYTES)
        .map_err(resource_error)?;
    if content_length(headers).is_some_and(|length| length > MAX_CONSUMER_BODY_BYTES) {
        return Err(body_too_large());
    }
    let bytes = to_bytes(body, MAX_CONSUMER_BODY_BYTES)
        .await
        .map_err(|_| body_too_large())?;
    let media_type = media_type(headers);
    match media_type.as_deref() {
        None | Some("application/json") => Ok(ConsumerInput {
            plaintext: bytes.to_vec(),
            sender: None,
            input_permit,
        }),
        Some(SEALED_CONTENT_TYPE) => {
            crate::pilot::validate_json_structure(&bytes).map_err(|error| {
                ApiError::new(
                    StatusCode::BAD_REQUEST,
                    "invalid_sealed_envelope",
                    "invalid_request_error",
                    error.to_string(),
                )
            })?;
            let envelope: SenderSealEnvelope = serde_json::from_slice(&bytes).map_err(|error| {
                ApiError::new(
                    StatusCode::BAD_REQUEST,
                    "invalid_sealed_envelope",
                    "invalid_request_error",
                    format!("sealed request body is not valid JSON: {error}"),
                )
            })?;
            let sender =
                X25519PublicKey::from_base64(&envelope.ephemeral_public_key).map_err(|_| {
                    ApiError::new(
                        StatusCode::BAD_REQUEST,
                        "invalid_sealed_envelope",
                        "invalid_request_error",
                        "ephemeral_public_key must be a canonical base64 X25519 key",
                    )
                })?;
            let plaintext = pilot.open_sender(&envelope).map_err(|error| {
                ApiError::new(
                    StatusCode::BAD_REQUEST,
                    "decryption_failed",
                    "invalid_request_error",
                    error.to_string(),
                )
            })?;
            if plaintext.len() > MAX_CONSUMER_BODY_BYTES {
                return Err(body_too_large());
            }
            Ok(ConsumerInput {
                plaintext,
                sender: Some(sender),
                input_permit,
            })
        }
        Some(_) => Err(ApiError::new(
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "unsupported_media_type",
            "invalid_request_error",
            "Content-Type must be application/json or application/eigeninference-sealed+json",
        )),
    }
}

fn content_length(headers: &HeaderMap) -> Option<usize> {
    headers
        .get(header::CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse().ok())
}

fn media_type(headers: &HeaderMap) -> Option<String> {
    headers
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .map(|value| {
            value
                .split(';')
                .next()
                .unwrap_or_default()
                .trim()
                .to_ascii_lowercase()
        })
}

fn body_too_large() -> ApiError {
    ApiError::new(
        StatusCode::PAYLOAD_TOO_LARGE,
        "request_too_large",
        "invalid_request_error",
        "request body exceeds the 2 MiB pilot limit",
    )
}

fn resource_error(error: PilotResourceError) -> ApiError {
    ApiError::capacity(error.to_string())
}
