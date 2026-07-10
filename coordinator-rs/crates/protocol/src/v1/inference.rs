use serde::{Deserialize, Serialize};

use crate::v1::{JsonNumber, OptionalNullable};

/// Current v1 NaCl Box JSON envelope.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EncryptedPayload {
    pub ephemeral_public_key: String,
    /// Standard-base64 `nonce[24] || ciphertext`.
    pub ciphertext: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatMessage {
    pub role: String,
    pub content: serde_json::Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InferenceRequestBody {
    pub model: String,
    #[serde(default, skip_serializing_if = "OptionalNullable::is_missing")]
    pub messages: OptionalNullable<Vec<ChatMessage>>,
    pub stream: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub temperature: Option<JsonNumber>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub endpoint: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InferenceRequest {
    pub request_id: String,
    #[serde(default, skip_serializing_if = "OptionalNullable::is_missing")]
    pub body: OptionalNullable<InferenceRequestBody>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub encrypted_body: Option<EncryptedPayload>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Cancel {
    pub request_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InferenceAccepted {
    pub request_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InferenceResponseChunk {
    pub request_id: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub data: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub encrypted_data: Option<EncryptedPayload>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UsageInfo {
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub reasoning_tokens: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InferenceComplete {
    pub request_id: String,
    pub usage: UsageInfo,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub se_signature: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub response_hash: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InferenceError {
    pub request_id: String,
    pub error: String,
    pub status_code: u16,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub error_reason: String,
}

pub type InferenceRequestMessage = InferenceRequest;
pub type CancelMessage = Cancel;
pub type InferenceAcceptedMessage = InferenceAccepted;
pub type InferenceResponseChunkMessage = InferenceResponseChunk;
pub type InferenceCompleteMessage = InferenceComplete;
pub type InferenceErrorMessage = InferenceError;

const fn is_zero_u64(value: &u64) -> bool {
    *value == 0
}
