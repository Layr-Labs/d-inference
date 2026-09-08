//! Shared descriptor types embedded in v1 messages.
//!
//! Field-for-field mirrors of the hardware/model/capacity/usage structs in
//! `coordinator/protocol/messages.go`. See the module docs in
//! [`super`](crate::json_v1) for the omitempty/`Option` mapping rules.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use super::omit::{is_false, is_zero_f64, is_zero_i64};

/// CPU core layout (Go `CPUCores`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct CpuCores {
    pub total: i64,
    pub performance: i64,
    pub efficiency: i64,
}

/// Provider machine capabilities (Go `Hardware`).
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Hardware {
    pub machine_model: String,
    pub chip_name: String,
    pub chip_family: String,
    pub chip_tier: String,
    pub memory_gb: i64,
    pub memory_available_gb: f64,
    pub cpu_cores: CpuCores,
    pub gpu_cores: i64,
    pub memory_bandwidth_gbs: f64,
}

/// A model available on a provider (Go `ModelInfo`).
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct ModelInfo {
    pub id: String,
    pub size_bytes: i64,
    pub model_type: String,
    pub quantization: String,
    /// SHA-256 fingerprint of weight files.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub weight_hash: String,
    /// True when the provider can serve this build with image/video input.
    /// Pre-v0.6.0 providers omit it (decodes to false).
    #[serde(skip_serializing_if = "is_false")]
    pub is_vision: bool,
    /// Chat-template render self-check result. Explicit `false` (the
    /// exclusion signal) must survive the wire, while a pre-0.6.5 provider
    /// with no opinion omits the key entirely — hence pointer semantics.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub template_render_ok: Option<bool>,
}

/// Live resource utilization reported in heartbeats (Go `SystemMetrics`).
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct SystemMetrics {
    /// 0.0 to 1.0.
    pub memory_pressure: f64,
    /// 0.0 to 1.0.
    pub cpu_usage: f64,
    /// nominal, fair, serious, critical.
    pub thermal_state: String,
}

/// Counters reported in heartbeats (Go `HeartbeatStats`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct HeartbeatStats {
    pub requests_served: i64,
    pub tokens_generated: i64,
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub cancellations_received: i64,
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub cancellations_before_output: i64,
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub cancellations_partial_complete: i64,
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub generation_errors_after_output: i64,
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub chunk_encryption_errors: i64,
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub stream_closed_without_terminal: i64,
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub cancel_during_model_load: i64,
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub usage_gaps: i64,
}

/// Capacity state of a single backend slot (Go `BackendSlotCapacity`).
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct BackendSlotCapacity {
    pub model: String,
    /// "running", "idle_shutdown", "crashed", "reloading".
    pub state: String,
    pub num_running: i64,
    pub num_waiting: i64,
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub max_concurrency: i64,
    pub active_tokens: i64,
    pub max_tokens_potential: i64,
    #[serde(skip_serializing_if = "is_zero_f64")]
    pub observed_decode_tps: f64,
    #[serde(skip_serializing_if = "is_zero_f64")]
    pub observed_prefill_tps: f64,
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub active_token_budget_used: i64,
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub active_token_budget_max: i64,
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub queued_token_budget: i64,
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub kv_bytes_per_token: i64,
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub model_load_time_ms: i64,
    // Engine-health (first-token wedge) diagnostics — measurement only.
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub steps_executed: i64,
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub admits: i64,
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub first_tokens_emitted: i64,
    #[serde(skip_serializing_if = "is_zero_f64")]
    pub seconds_since_last_step: f64,
    #[serde(skip_serializing_if = "is_zero_f64")]
    pub seconds_since_last_first_token: f64,
    #[serde(skip_serializing_if = "is_false")]
    pub wedge_suspected: bool,
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub eval_in_flight_ms: i64,
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub idle_clear_in_flight_ms: i64,
}

/// Aggregate capacity across all backend slots (Go `BackendCapacity`).
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct BackendCapacity {
    /// No `omitempty` in Go: a nil slice serializes as JSON `null`.
    pub slots: Option<Vec<BackendSlotCapacity>>,
    pub gpu_memory_active_gb: f64,
    pub gpu_memory_peak_gb: f64,
    pub gpu_memory_cache_gb: f64,
    pub total_memory_gb: f64,
    /// Max additional model-weight footprint (GB) loadable right now.
    /// `None` for legacy providers that don't report it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub free_for_load_gb: Option<f64>,
}

/// Provider privacy invariants at registration time (Go
/// `PrivacyCapabilities`).
///
/// Legacy providers (< v0.6.31) also send a `hypervisor_active` key here;
/// the concept is retired and intentionally not modeled — unknown fields
/// are ignored on decode, matching Go.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct PrivacyCapabilities {
    pub text_backend_inprocess: bool,
    pub text_proxy_disabled: bool,
    pub python_runtime_locked: bool,
    pub dangerous_modules_blocked: bool,
    pub sip_enabled: bool,
    pub anti_debug_enabled: bool,
    pub core_dumps_disabled: bool,
    pub env_scrubbed: bool,
}

/// Token usage information (Go `UsageInfo`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct UsageInfo {
    pub prompt_tokens: i64,
    pub completion_tokens: i64,
    /// Subset of `completion_tokens` spent on reasoning content; 0 (omitted)
    /// for non-reasoning responses and older providers.
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub reasoning_tokens: i64,
}

/// A NaCl Box encrypted message (Go `EncryptedPayload`).
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct EncryptedPayload {
    /// Sender's ephemeral X25519 public key (base64, 32 bytes decoded).
    pub ephemeral_public_key: String,
    /// base64 of: 24-byte nonce || NaCl Box encrypted+authenticated data.
    pub ciphertext: String,
}

/// A single message in the OpenAI chat format (Go `ChatMessage`).
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct ChatMessage {
    pub role: String,
    pub content: String,
}

/// Body carried inside an `inference_request` (Go `InferenceRequestBody`).
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct InferenceRequestBody {
    pub model: String,
    /// No `omitempty` in Go: a nil slice serializes as JSON `null`.
    pub messages: Option<Vec<ChatMessage>>,
    pub stream: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temperature: Option<f64>,
    /// Backend path to forward to; defaults to "/v1/chat/completions" when
    /// empty, for backwards compatibility.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub endpoint: String,
}

/// Desired build for one public model name (Go `DesiredModelEntry`).
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct DesiredModelEntry {
    pub model_name: String,
    pub desired_build: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub previous_build: String,
}

/// One component whose hash did not match the known-good manifest (Go
/// `RuntimeMismatch`).
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct RuntimeMismatch {
    pub component: String,
    pub expected: String,
    pub got: String,
}

/// Sorted-key string map used for `template_hashes` / `model_hashes`.
/// `BTreeMap` matches Go's sorted map-key marshaling byte-for-byte.
pub(crate) type HashMapSorted = BTreeMap<String, String>;
