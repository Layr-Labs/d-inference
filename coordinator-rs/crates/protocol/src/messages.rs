use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Known provider/coordinator WebSocket message type strings (protocol v1).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MessageType {
    Register,
    Heartbeat,
    InferenceAccepted,
    InferenceResponseChunk,
    InferenceComplete,
    InferenceError,
    InferenceRequest,
    Cancel,
    LoadModel,
    LoadModelStatus,
    PrefetchModel,
    PrefetchModelStatus,
    DesiredModels,
    ModelsUpdate,
    AttestationChallenge,
    AttestationResponse,
    CodeAttestationResponse,
    RuntimeStatus,
    TrustStatus,
    // Protocol v2
    Prepare,
    Prepared,
    Start,
    Started,
    Abort,
    Aborted,
    Cancelled,
    ProviderTerminal,
    TerminalAck,
    ModelReady,
    ModelGone,
    StructuredError,
    #[serde(other)]
    Unknown,
}

impl MessageType {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Register => "register",
            Self::Heartbeat => "heartbeat",
            Self::InferenceAccepted => "inference_accepted",
            Self::InferenceResponseChunk => "inference_response_chunk",
            Self::InferenceComplete => "inference_complete",
            Self::InferenceError => "inference_error",
            Self::InferenceRequest => "inference_request",
            Self::Cancel => "cancel",
            Self::LoadModel => "load_model",
            Self::LoadModelStatus => "load_model_status",
            Self::PrefetchModel => "prefetch_model",
            Self::PrefetchModelStatus => "prefetch_model_status",
            Self::DesiredModels => "desired_models",
            Self::ModelsUpdate => "models_update",
            Self::AttestationChallenge => "attestation_challenge",
            Self::AttestationResponse => "attestation_response",
            Self::CodeAttestationResponse => "code_attestation_response",
            Self::RuntimeStatus => "runtime_status",
            Self::TrustStatus => "trust_status",
            Self::Prepare => "prepare",
            Self::Prepared => "prepared",
            Self::Start => "start",
            Self::Started => "started",
            Self::Abort => "abort",
            Self::Aborted => "aborted",
            Self::Cancelled => "cancelled",
            Self::ProviderTerminal => "provider_terminal",
            Self::TerminalAck => "terminal_ack",
            Self::ModelReady => "model_ready",
            Self::ModelGone => "model_gone",
            Self::StructuredError => "structured_error",
            Self::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Error)]
pub enum ProtocolError {
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
    #[error("missing type field")]
    MissingType,
}

/// Minimal envelope used to scan the `type` field before full decode.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WireMessage {
    #[serde(rename = "type")]
    pub msg_type: String,
    #[serde(flatten)]
    pub rest: serde_json::Map<String, serde_json::Value>,
}

impl WireMessage {
    pub fn parse(bytes: &[u8]) -> Result<Self, ProtocolError> {
        Ok(serde_json::from_slice(bytes)?)
    }

    pub fn message_type(&self) -> MessageType {
        match self.msg_type.as_str() {
            "register" => MessageType::Register,
            "heartbeat" => MessageType::Heartbeat,
            "inference_accepted" => MessageType::InferenceAccepted,
            "inference_response_chunk" => MessageType::InferenceResponseChunk,
            "inference_complete" => MessageType::InferenceComplete,
            "inference_error" => MessageType::InferenceError,
            "inference_request" => MessageType::InferenceRequest,
            "cancel" => MessageType::Cancel,
            "load_model" => MessageType::LoadModel,
            "load_model_status" => MessageType::LoadModelStatus,
            "prefetch_model" => MessageType::PrefetchModel,
            "prefetch_model_status" => MessageType::PrefetchModelStatus,
            "desired_models" => MessageType::DesiredModels,
            "models_update" => MessageType::ModelsUpdate,
            "attestation_challenge" => MessageType::AttestationChallenge,
            "attestation_response" => MessageType::AttestationResponse,
            "code_attestation_response" => MessageType::CodeAttestationResponse,
            "runtime_status" => MessageType::RuntimeStatus,
            "trust_status" => MessageType::TrustStatus,
            "prepare" => MessageType::Prepare,
            "prepared" => MessageType::Prepared,
            "start" => MessageType::Start,
            "started" => MessageType::Started,
            "abort" => MessageType::Abort,
            "aborted" => MessageType::Aborted,
            "cancelled" => MessageType::Cancelled,
            "provider_terminal" => MessageType::ProviderTerminal,
            "terminal_ack" => MessageType::TerminalAck,
            "model_ready" => MessageType::ModelReady,
            "model_gone" => MessageType::ModelGone,
            "structured_error" => MessageType::StructuredError,
            _ => MessageType::Unknown,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_type_field() {
        let raw = br#"{"type":"heartbeat","provider_id":"p1"}"#;
        let msg = WireMessage::parse(raw).unwrap();
        assert_eq!(msg.message_type(), MessageType::Heartbeat);
        assert_eq!(msg.rest.get("provider_id").and_then(|v| v.as_str()), Some("p1"));
    }
}

#[cfg(test)]
mod flatten_tests {
    use super::*;

    #[test]
    fn prepared_flatten_keeps_attempt_id() {
        let raw = br#"{"type":"prepared","attempt_id":"a1","lease_ttl_ms":1,"prompt_tokens":1,"max_output_tokens":1,"engine_queue_depth":0,"prefill_can_begin":true}"#;
        let msg = WireMessage::parse(raw).unwrap();
        assert_eq!(msg.message_type(), MessageType::Prepared);
        assert_eq!(msg.rest.get("attempt_id").and_then(|v| v.as_str()), Some("a1"));
    }
}
