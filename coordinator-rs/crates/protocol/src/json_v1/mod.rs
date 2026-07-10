//! JSON v1 provider wire protocol.
//!
//! Mirrors `coordinator/protocol/messages.go` exactly. The Go encoder is
//! ground truth for this module:
//!
//! - Every `#[serde(skip_serializing_if = ...)]` matches a Go `omitempty` tag
//!   field-for-field. Go omits `false`, `0`, `0.0`, `""`, nil pointers, and
//!   nil/empty slices/maps; fields without `omitempty` are always emitted
//!   (a nil Go slice without `omitempty` serializes as JSON `null`, which is
//!   why "always present" slices are modeled as `Option<Vec<T>>`).
//! - Go `omitempty` on a *struct-typed* field is a no-op (structs are never
//!   "empty" to `encoding/json`), so e.g. `InferenceRequestMessage.body` is
//!   always serialized even when zero-valued.
//! - `json.RawMessage` fields are `Option<Box<RawValue>>` so signed
//!   attestation blobs round-trip byte-exact (plan §15.3: never deserialize
//!   and reserialize signed input before hashing).
//! - Decode is lenient like Go: unknown JSON fields are ignored and missing
//!   fields take the struct's zero value (`#[serde(default)]` on every
//!   container, with `Default` impls that also pre-fill the wire `type` tag).
//!
//! Frame dispatch mirrors `type_scan.go`: [`peek_type`] is a conservative
//! single-pass byte scanner; [`ProviderMessage::decode`] /
//! [`CoordinatorMessage::decode`] fall back to a full envelope decode when
//! the scanner is unsure, then unmarshal the concrete struct exactly once.

mod coordinator_messages;
mod envelope;
mod omit;
mod provider_messages;
mod type_scan;
mod types;

pub use coordinator_messages::{
    AttestationChallengeMessage, CancelMessage, DesiredModelsMessage, InferenceRequestMessage,
    LoadModelMessage, PrefetchModelMessage, RuntimeStatusMessage, TrustStatusMessage,
};
pub use envelope::{CoordinatorMessage, DecodeError, ProviderMessage};
pub use provider_messages::{
    AttestationResponseMessage, CodeAttestationResponseMessage, HeartbeatMessage,
    InferenceAcceptedMessage, InferenceCompleteMessage, InferenceErrorMessage,
    InferenceResponseChunkMessage, LoadModelStatusMessage, ModelsUpdateMessage,
    PrefetchModelStatusMessage, RegisterMessage,
};
pub use type_scan::peek_type;
pub use types::{
    BackendCapacity, BackendSlotCapacity, ChatMessage, CpuCores, DesiredModelEntry,
    EncryptedPayload, Hardware, HeartbeatStats, InferenceRequestBody, ModelInfo,
    PrivacyCapabilities, RuntimeMismatch, SystemMetrics, UsageInfo,
};

/// Message type constants, mirroring the Go `Type*` constants.
pub mod msg_type {
    // Provider → Coordinator.
    pub const REGISTER: &str = "register";
    pub const HEARTBEAT: &str = "heartbeat";
    pub const INFERENCE_ACCEPTED: &str = "inference_accepted";
    pub const INFERENCE_RESPONSE_CHUNK: &str = "inference_response_chunk";
    pub const INFERENCE_COMPLETE: &str = "inference_complete";
    pub const INFERENCE_ERROR: &str = "inference_error";
    pub const ATTESTATION_RESPONSE: &str = "attestation_response";
    pub const CODE_ATTESTATION_RESPONSE: &str = "code_attestation_response";
    pub const LOAD_MODEL_STATUS: &str = "load_model_status";
    pub const PREFETCH_MODEL_STATUS: &str = "prefetch_model_status";
    pub const MODELS_UPDATE: &str = "models_update";

    // Coordinator → Provider.
    pub const INFERENCE_REQUEST: &str = "inference_request";
    pub const CANCEL: &str = "cancel";
    pub const ATTESTATION_CHALLENGE: &str = "attestation_challenge";
    pub const RUNTIME_STATUS: &str = "runtime_status";
    pub const LOAD_MODEL: &str = "load_model";
    pub const PREFETCH_MODEL: &str = "prefetch_model";
    pub const DESIRED_MODELS: &str = "desired_models";
    pub const TRUST_STATUS: &str = "trust_status";
}

/// Lifecycle states reported in `load_model_status`.
pub mod load_model_status {
    pub const STARTED: &str = "started";
    pub const SUCCEEDED: &str = "succeeded";
    pub const FAILED: &str = "failed";
}

/// Lifecycle states reported in `prefetch_model_status`. "verified" (not
/// "succeeded") is the terminal success state: the build is on disk and
/// hash-checked but not loaded into GPU memory.
pub mod prefetch_model_status {
    pub const STARTED: &str = "started";
    pub const DOWNLOADING: &str = "downloading";
    pub const VERIFIED: &str = "verified";
    pub const FAILED: &str = "failed";
}

/// Well-known error reason a provider attaches to rejections while draining
/// ahead of an auto-update restart. The coordinator matches this exact string
/// (mirrored in Go `protocol.ProviderDrainingForUpdate` and the Swift
/// provider's `Types.swift`).
pub const PROVIDER_DRAINING_FOR_UPDATE: &str = "provider draining for update";
