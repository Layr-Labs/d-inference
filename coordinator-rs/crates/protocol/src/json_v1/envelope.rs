//! Frame envelopes: single-parse decode of provider and coordinator frames.
//!
//! Mirrors Go's `ProviderMessage.UnmarshalJSON`: the cheap
//! [`peek_type`](super::peek_type) scanner reads the `type` discriminator; if
//! it is unsure the decoder falls back to a full envelope pass, then the
//! concrete struct is unmarshaled exactly once.
//!
//! Privacy: [`DecodeError`] never embeds frame bytes or field values — only
//! the frame type and the parser's line/column position survive into the
//! error, so a failed decode of a plaintext body cannot leak prompt content
//! into logs.

use serde::{de::DeserializeOwned, Deserialize, Serialize};

use super::coordinator_messages::*;
use super::msg_type;
use super::provider_messages::*;
use super::type_scan::peek_type;

/// A decode failure with all content stripped.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum DecodeError {
    /// The frame had no readable top-level `type` string.
    #[error("failed to read message type (line {line}, column {column})")]
    MissingType { line: usize, column: usize },
    /// The `type` value is not a known message type.
    #[error("unknown message type {0:?}")]
    UnknownType(String),
    /// The concrete struct failed to unmarshal.
    #[error("failed to decode {msg_type} message (line {line}, column {column})")]
    Payload {
        msg_type: &'static str,
        line: usize,
        column: usize,
    },
}

#[derive(Deserialize)]
struct Envelope {
    #[serde(rename = "type", default)]
    message_type: String,
}

/// Reads the `type` discriminator: scanner fast path, envelope fallback.
fn frame_type(data: &[u8]) -> Result<String, DecodeError> {
    if let Some(t) = peek_type(data) {
        return Ok(t.to_owned());
    }
    match serde_json::from_slice::<Envelope>(data) {
        Ok(env) => Ok(env.message_type),
        Err(e) => Err(DecodeError::MissingType {
            line: e.line(),
            column: e.column(),
        }),
    }
}

fn decode_payload<T: DeserializeOwned>(
    msg_type: &'static str,
    data: &[u8],
) -> Result<T, DecodeError> {
    serde_json::from_slice(data).map_err(|e| DecodeError::Payload {
        msg_type,
        line: e.line(),
        column: e.column(),
    })
}

macro_rules! envelope {
    (
        $(#[doc = $doc:literal])*
        $name:ident { $($variant:ident($msg:ty) = $tag:path,)+ }
    ) => {
        $(#[doc = $doc])*
        #[derive(Debug, Clone, Serialize)]
        #[serde(untagged)]
        pub enum $name {
            $($variant($msg),)+
        }

        impl $name {
            /// Decodes one frame, parsing the JSON exactly once on the fast
            /// path. Unknown types are a typed error, mirroring Go.
            pub fn decode(data: &[u8]) -> Result<Self, DecodeError> {
                let t = frame_type(data)?;
                match t.as_str() {
                    $($tag => Ok(Self::$variant(decode_payload($tag, data)?)),)+
                    _ => Err(DecodeError::UnknownType(t)),
                }
            }

            /// The wire `type` tag for this frame.
            pub fn type_str(&self) -> &'static str {
                match self {
                    $(Self::$variant(_) => $tag,)+
                }
            }

            /// Encodes the frame as a JSON byte vector.
            pub fn encode(&self) -> serde_json::Result<Vec<u8>> {
                serde_json::to_vec(self)
            }
        }
    };
}

envelope! {
    /// Any provider → coordinator frame (Go `ProviderMessage` envelope).
    ProviderMessage {
        Register(RegisterMessage) = msg_type::REGISTER,
        Heartbeat(HeartbeatMessage) = msg_type::HEARTBEAT,
        InferenceAccepted(InferenceAcceptedMessage) = msg_type::INFERENCE_ACCEPTED,
        InferenceResponseChunk(InferenceResponseChunkMessage) = msg_type::INFERENCE_RESPONSE_CHUNK,
        InferenceComplete(InferenceCompleteMessage) = msg_type::INFERENCE_COMPLETE,
        InferenceError(InferenceErrorMessage) = msg_type::INFERENCE_ERROR,
        AttestationResponse(AttestationResponseMessage) = msg_type::ATTESTATION_RESPONSE,
        CodeAttestationResponse(CodeAttestationResponseMessage) = msg_type::CODE_ATTESTATION_RESPONSE,
        LoadModelStatus(LoadModelStatusMessage) = msg_type::LOAD_MODEL_STATUS,
        PrefetchModelStatus(PrefetchModelStatusMessage) = msg_type::PREFETCH_MODEL_STATUS,
        ModelsUpdate(ModelsUpdateMessage) = msg_type::MODELS_UPDATE,
    }
}

envelope! {
    /// Any coordinator → provider frame (the Swift provider decodes these).
    CoordinatorMessage {
        InferenceRequest(InferenceRequestMessage) = msg_type::INFERENCE_REQUEST,
        Cancel(CancelMessage) = msg_type::CANCEL,
        AttestationChallenge(AttestationChallengeMessage) = msg_type::ATTESTATION_CHALLENGE,
        RuntimeStatus(RuntimeStatusMessage) = msg_type::RUNTIME_STATUS,
        LoadModel(LoadModelMessage) = msg_type::LOAD_MODEL,
        PrefetchModel(PrefetchModelMessage) = msg_type::PREFETCH_MODEL,
        DesiredModels(DesiredModelsMessage) = msg_type::DESIRED_MODELS,
        TrustStatus(TrustStatusMessage) = msg_type::TRUST_STATUS,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_via_fast_path() {
        let frame = br#"{"type":"cancel","request_id":"r-1"}"#;
        match ProviderMessage::decode(frame) {
            Err(DecodeError::UnknownType(t)) => assert_eq!(t, "cancel"),
            other => panic!("expected unknown type for provider envelope, got {other:?}"),
        }
        match CoordinatorMessage::decode(frame).expect("decode") {
            CoordinatorMessage::Cancel(m) => assert_eq!(m.request_id, "r-1"),
            other => panic!("wrong variant: {other:?}"),
        }
    }

    #[test]
    fn decodes_via_envelope_fallback() {
        // Escaped type value defeats the scanner but not the full decode.
        let frame = br#"{"type":"canc\u0065l","request_id":"r-2"}"#;
        match CoordinatorMessage::decode(frame).expect("decode") {
            CoordinatorMessage::Cancel(m) => assert_eq!(m.request_id, "r-2"),
            other => panic!("wrong variant: {other:?}"),
        }
    }

    #[test]
    fn unknown_type_is_typed_error() {
        let err = ProviderMessage::decode(br#"{"type":"nope"}"#).unwrap_err();
        assert_eq!(err, DecodeError::UnknownType("nope".to_owned()));
    }

    #[test]
    fn malformed_frame_reports_position_only() {
        let err = ProviderMessage::decode(b"not json at all").unwrap_err();
        match err {
            DecodeError::MissingType { .. } => {}
            other => panic!("expected MissingType, got {other:?}"),
        }
    }

    #[test]
    fn payload_error_carries_no_content() {
        // status_code must be a number; the error must not echo the value.
        let frame =
            br#"{"type":"inference_error","request_id":"r","error":"x","status_code":"SECRET"}"#;
        let err = ProviderMessage::decode(frame).unwrap_err();
        let msg = err.to_string();
        assert!(!msg.contains("SECRET"), "error leaked content: {msg}");
    }

    #[test]
    fn missing_fields_default_like_go() {
        let frame = br#"{"type":"heartbeat"}"#;
        match ProviderMessage::decode(frame).expect("decode") {
            ProviderMessage::Heartbeat(m) => {
                assert_eq!(m.status, "");
                assert_eq!(m.active_model, None);
                assert!(m.warm_models.is_empty());
                assert!(m.backend_capacity.is_none());
            }
            other => panic!("wrong variant: {other:?}"),
        }
    }

    #[test]
    fn encode_emits_type_tag() {
        let msg = CoordinatorMessage::Cancel(CancelMessage {
            request_id: "abc".into(),
            ..Default::default()
        });
        let bytes = msg.encode().expect("encode");
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&bytes).unwrap(),
            serde_json::json!({"type":"cancel","request_id":"abc"})
        );
    }
}
