//! Provider → coordinator v1 messages.
//!
//! Each struct carries its wire `type` tag as a plain field (mirroring the Go
//! structs); `Default` pre-fills the correct tag so zero-valued frames encode
//! exactly like their Go counterparts.

use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;

use super::msg_type;
use super::omit::{is_false, is_zero_f64, is_zero_i64};
use super::types::{
    BackendCapacity, EncryptedPayload, Hardware, HashMapSorted, HeartbeatStats, ModelInfo,
    PrivacyCapabilities, SystemMetrics, UsageInfo,
};

/// Sent when a provider first connects (Go `RegisterMessage`).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct RegisterMessage {
    #[serde(rename = "type")]
    pub message_type: String,
    pub hardware: Hardware,
    /// No `omitempty` in Go: a nil slice serializes as JSON `null`.
    pub models: Option<Vec<ModelInfo>>,
    pub backend: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub version: String,
    /// base64-encoded X25519 public key for E2E encryption.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub public_key: String,
    #[serde(skip_serializing_if = "is_false")]
    pub encrypted_response_chunks: bool,
    /// Signed Secure Enclave attestation blob. Kept as raw JSON so the exact
    /// signed bytes survive decode → re-encode (signature verification hashes
    /// the original bytes; see plan §15.3).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub attestation: Option<Box<RawValue>>,
    #[serde(skip_serializing_if = "is_zero_f64")]
    pub prefill_tps: f64,
    #[serde(skip_serializing_if = "is_zero_f64")]
    pub decode_tps: f64,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub auth_token: String,
    #[serde(skip_serializing_if = "is_false")]
    pub private_only: bool,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub apns_device_token: String,
    /// "production" | "development".
    #[serde(skip_serializing_if = "String::is_empty")]
    pub apns_environment: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub python_hash: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub runtime_hash: String,
    #[serde(skip_serializing_if = "HashMapSorted::is_empty")]
    pub template_hashes: HashMapSorted,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub privacy_capabilities: Option<PrivacyCapabilities>,
}

impl Default for RegisterMessage {
    fn default() -> Self {
        Self {
            message_type: msg_type::REGISTER.to_owned(),
            hardware: Hardware::default(),
            models: None,
            backend: String::new(),
            version: String::new(),
            public_key: String::new(),
            encrypted_response_chunks: false,
            attestation: None,
            prefill_tps: 0.0,
            decode_tps: 0.0,
            auth_token: String::new(),
            private_only: false,
            apns_device_token: String::new(),
            apns_environment: String::new(),
            python_hash: String::new(),
            runtime_hash: String::new(),
            template_hashes: HashMapSorted::new(),
            privacy_capabilities: None,
        }
    }
}

/// Sent periodically by connected providers (Go `HeartbeatMessage`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct HeartbeatMessage {
    #[serde(rename = "type")]
    pub message_type: String,
    pub status: String,
    /// No `omitempty` in Go: `null` means no model loaded.
    pub active_model: Option<String>,
    pub stats: HeartbeatStats,
    /// Models currently loaded in memory.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub warm_models: Vec<String>,
    pub system_metrics: SystemMetrics,
    /// Live backend capacity (`None` for old providers).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub backend_capacity: Option<BackendCapacity>,
    /// Late/rotated APNs token carried outside registration; never by itself
    /// grants CodeAttested.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub apns_device_token: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub apns_environment: String,
}

impl Default for HeartbeatMessage {
    fn default() -> Self {
        Self {
            message_type: msg_type::HEARTBEAT.to_owned(),
            status: String::new(),
            active_model: None,
            stats: HeartbeatStats::default(),
            warm_models: Vec::new(),
            system_metrics: SystemMetrics::default(),
            backend_capacity: None,
            apns_device_token: String::new(),
            apns_environment: String::new(),
        }
    }
}

/// Provider accepted the request and is working on it (Go
/// `InferenceAcceptedMessage`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct InferenceAcceptedMessage {
    #[serde(rename = "type")]
    pub message_type: String,
    pub request_id: String,
}

impl Default for InferenceAcceptedMessage {
    fn default() -> Self {
        Self {
            message_type: msg_type::INFERENCE_ACCEPTED.to_owned(),
            request_id: String::new(),
        }
    }
}

/// A single SSE chunk from the provider (Go `InferenceResponseChunkMessage`).
/// When E2E encryption is active, `data` is empty and `encrypted_data`
/// carries the encrypted chunk.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct InferenceResponseChunkMessage {
    #[serde(rename = "type")]
    pub message_type: String,
    pub request_id: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub data: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub encrypted_data: Option<EncryptedPayload>,
}

impl Default for InferenceResponseChunkMessage {
    fn default() -> Self {
        Self {
            message_type: msg_type::INFERENCE_RESPONSE_CHUNK.to_owned(),
            request_id: String::new(),
            data: String::new(),
            encrypted_data: None,
        }
    }
}

/// Provider finished generating (Go `InferenceCompleteMessage`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct InferenceCompleteMessage {
    #[serde(rename = "type")]
    pub message_type: String,
    pub request_id: String,
    pub usage: UsageInfo,
    /// SE-signed response hash.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub se_signature: String,
    /// SHA-256 of response data.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub response_hash: String,
}

impl Default for InferenceCompleteMessage {
    fn default() -> Self {
        Self {
            message_type: msg_type::INFERENCE_COMPLETE.to_owned(),
            request_id: String::new(),
            usage: UsageInfo::default(),
            se_signature: String::new(),
            response_hash: String::new(),
        }
    }
}

/// An error during inference (Go `InferenceErrorMessage`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct InferenceErrorMessage {
    #[serde(rename = "type")]
    pub message_type: String,
    pub request_id: String,
    pub error: String,
    pub status_code: i64,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub error_reason: String,
}

impl Default for InferenceErrorMessage {
    fn default() -> Self {
        Self {
            message_type: msg_type::INFERENCE_ERROR.to_owned(),
            request_id: String::new(),
            error: String::new(),
            status_code: 0,
            error_reason: String::new(),
        }
    }
}

/// Response to an attestation challenge (Go `AttestationResponseMessage`).
///
/// `signature` covers nonce + timestamp only; `status_signature` (v0.3.11+)
/// covers the canonical status JSON built by
/// [`crate::crypto::signing::build_status_canonical`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct AttestationResponseMessage {
    #[serde(rename = "type")]
    pub message_type: String,
    /// Echoed back from the challenge.
    pub nonce: String,
    /// base64-encoded signature of nonce+timestamp.
    pub signature: String,
    /// base64-encoded signature of canonical status JSON.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub status_signature: String,
    /// base64-encoded public key.
    pub public_key: String,
    /// Legacy fleet compat only: providers < v0.6.31 sign `hypervisor_active`
    /// into the canonical status, so this field must keep decoding for their
    /// `status_signature` to verify. New providers omit it. Remove once the
    /// fleet floor passes v0.6.31.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hypervisor_active: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rdma_disabled: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sip_enabled: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub secure_boot_enabled: Option<bool>,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub binary_hash: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub active_model_hash: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub python_hash: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub runtime_hash: String,
    #[serde(skip_serializing_if = "HashMapSorted::is_empty")]
    pub template_hashes: HashMapSorted,
    #[serde(skip_serializing_if = "HashMapSorted::is_empty")]
    pub model_hashes: HashMapSorted,
}

impl Default for AttestationResponseMessage {
    fn default() -> Self {
        Self {
            message_type: msg_type::ATTESTATION_RESPONSE.to_owned(),
            nonce: String::new(),
            signature: String::new(),
            status_signature: String::new(),
            public_key: String::new(),
            hypervisor_active: None,
            rdma_disabled: None,
            sip_enabled: None,
            secure_boot_enabled: None,
            binary_hash: String::new(),
            active_model_hash: String::new(),
            python_hash: String::new(),
            runtime_hash: String::new(),
            template_hashes: HashMapSorted::new(),
            model_hashes: HashMapSorted::new(),
        }
    }
}

/// Reply to the APNs-delivered code-identity challenge (Go
/// `CodeAttestationResponseMessage`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct CodeAttestationResponseMessage {
    #[serde(rename = "type")]
    pub message_type: String,
    /// Decrypted challenge nonce, base64 (must equal the pushed nonce).
    pub nonce: String,
    /// base64 SE-key (P-256) signature over the nonce bytes.
    pub signature: String,
}

impl Default for CodeAttestationResponseMessage {
    fn default() -> Self {
        Self {
            message_type: msg_type::CODE_ATTESTATION_RESPONSE.to_owned(),
            nonce: String::new(),
            signature: String::new(),
        }
    }
}

/// Provider's reply to a `load_model` command (Go `LoadModelStatusMessage`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct LoadModelStatusMessage {
    #[serde(rename = "type")]
    pub message_type: String,
    pub model_id: String,
    /// One of [`super::load_model_status`].
    pub status: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub error: String,
}

impl Default for LoadModelStatusMessage {
    fn default() -> Self {
        Self {
            message_type: msg_type::LOAD_MODEL_STATUS.to_owned(),
            model_id: String::new(),
            status: String::new(),
            error: String::new(),
        }
    }
}

/// Provider's progress/terminal reply to a `prefetch_model` command (Go
/// `PrefetchModelStatusMessage`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct PrefetchModelStatusMessage {
    #[serde(rename = "type")]
    pub message_type: String,
    pub model_id: String,
    /// One of [`super::prefetch_model_status`].
    pub status: String,
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub bytes_done: i64,
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub bytes_total: i64,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub error: String,
}

impl Default for PrefetchModelStatusMessage {
    fn default() -> Self {
        Self {
            message_type: msg_type::PREFETCH_MODEL_STATUS.to_owned(),
            model_id: String::new(),
            status: String::new(),
            bytes_done: 0,
            bytes_total: 0,
            error: String::new(),
        }
    }
}

/// Authoritative out-of-band update to the provider's advertised model
/// inventory (Go `ModelsUpdateMessage`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ModelsUpdateMessage {
    #[serde(rename = "type")]
    pub message_type: String,
    /// No `omitempty` in Go: a nil slice serializes as JSON `null`.
    pub models: Option<Vec<ModelInfo>>,
}

impl Default for ModelsUpdateMessage {
    fn default() -> Self {
        Self {
            message_type: msg_type::MODELS_UPDATE.to_owned(),
            models: None,
        }
    }
}
