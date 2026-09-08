//! Coordinator → provider v1 messages.
//!
//! Each struct carries its wire `type` tag as a plain field (mirroring the Go
//! structs); `Default` pre-fills the correct tag so zero-valued frames encode
//! exactly like their Go counterparts.

use serde::{Deserialize, Serialize};

use super::msg_type;
use super::omit::is_zero_i64;
use super::types::{DesiredModelEntry, EncryptedPayload, InferenceRequestBody, RuntimeMismatch};

/// Tells a provider to run inference (Go `InferenceRequestMessage`).
///
/// When E2E encryption is enabled, `body` is zero-valued and `encrypted_body`
/// carries the NaCl Box encrypted request. Go tags `body` with `omitempty`,
/// but `omitempty` is a no-op on struct-typed fields, so `body` is ALWAYS on
/// the wire — the Swift strict decoder depends on that.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct InferenceRequestMessage {
    #[serde(rename = "type")]
    pub message_type: String,
    pub request_id: String,
    pub body: InferenceRequestBody,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub encrypted_body: Option<EncryptedPayload>,
}

impl Default for InferenceRequestMessage {
    fn default() -> Self {
        Self {
            message_type: msg_type::INFERENCE_REQUEST.to_owned(),
            request_id: String::new(),
            body: InferenceRequestBody::default(),
            encrypted_body: None,
        }
    }
}

/// Tells a provider to cancel an in-flight request (Go `CancelMessage`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct CancelMessage {
    #[serde(rename = "type")]
    pub message_type: String,
    pub request_id: String,
}

impl Default for CancelMessage {
    fn default() -> Self {
        Self {
            message_type: msg_type::CANCEL.to_owned(),
            request_id: String::new(),
        }
    }
}

/// Challenges a provider to prove it still holds its private key (Go
/// `AttestationChallengeMessage`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct AttestationChallengeMessage {
    #[serde(rename = "type")]
    pub message_type: String,
    /// base64-encoded random 32-byte nonce.
    pub nonce: String,
    /// ISO 8601 timestamp.
    pub timestamp: String,
}

impl Default for AttestationChallengeMessage {
    fn default() -> Self {
        Self {
            message_type: msg_type::ATTESTATION_CHALLENGE.to_owned(),
            nonce: String::new(),
            timestamp: String::new(),
        }
    }
}

/// Result of a provider's runtime integrity verification (Go
/// `RuntimeStatusMessage`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct RuntimeStatusMessage {
    #[serde(rename = "type")]
    pub message_type: String,
    pub verified: bool,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub mismatches: Vec<RuntimeMismatch>,
}

impl Default for RuntimeStatusMessage {
    fn default() -> Self {
        Self {
            message_type: msg_type::RUNTIME_STATUS.to_owned(),
            verified: false,
            mismatches: Vec::new(),
        }
    }
}

/// Instructs a provider to eagerly load (and pin) a model (Go
/// `LoadModelMessage`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct LoadModelMessage {
    #[serde(rename = "type")]
    pub message_type: String,
    pub model_id: String,
}

impl Default for LoadModelMessage {
    fn default() -> Self {
        Self {
            message_type: msg_type::LOAD_MODEL.to_owned(),
            model_id: String::new(),
        }
    }
}

/// Instructs a provider to download AND verify a model build without loading
/// it into GPU memory (Go `PrefetchModelMessage`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct PrefetchModelMessage {
    #[serde(rename = "type")]
    pub message_type: String,
    pub model_id: String,
    /// Advisory hint (higher = more urgent).
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub priority: i64,
}

impl Default for PrefetchModelMessage {
    fn default() -> Self {
        Self {
            message_type: msg_type::PREFETCH_MODEL.to_owned(),
            model_id: String::new(),
            priority: 0,
        }
    }
}

/// Declarative statement of the desired build per public model name (Go
/// `DesiredModelsMessage`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct DesiredModelsMessage {
    #[serde(rename = "type")]
    pub message_type: String,
    /// No `omitempty` in Go: a nil slice serializes as JSON `null`.
    pub models: Option<Vec<DesiredModelEntry>>,
}

impl Default for DesiredModelsMessage {
    fn default() -> Self {
        Self {
            message_type: msg_type::DESIRED_MODELS.to_owned(),
            models: None,
        }
    }
}

/// Informs a provider of its current trust level (Go `TrustStatusMessage`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct TrustStatusMessage {
    #[serde(rename = "type")]
    pub message_type: String,
    /// "none", "self_signed", "hardware".
    pub trust_level: String,
    /// "online", "untrusted", etc.
    pub status: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub reason: String,
}

impl Default for TrustStatusMessage {
    fn default() -> Self {
        Self {
            message_type: msg_type::TRUST_STATUS.to_owned(),
            trust_level: String::new(),
            status: String::new(),
            reason: String::new(),
        }
    }
}
