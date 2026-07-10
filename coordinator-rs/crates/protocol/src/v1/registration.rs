use serde::{Deserialize, Serialize};

use crate::{
    error::ProtocolError,
    v1::{JsonNumber, OptionalNullable, model::ModelInfo},
    v2::{ProtocolCapabilities, ProviderProcessGenerationId},
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CpuCores {
    pub total: u32,
    pub performance: u32,
    pub efficiency: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Hardware {
    pub machine_model: String,
    pub chip_name: String,
    pub chip_family: String,
    pub chip_tier: String,
    pub memory_gb: u32,
    pub memory_available_gb: JsonNumber,
    pub cpu_cores: CpuCores,
    pub gpu_cores: u32,
    pub memory_bandwidth_gbs: JsonNumber,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Debug, Serialize, Deserialize)]
pub struct Registration {
    pub hardware: Hardware,
    pub models: Vec<ModelInfo>,
    pub backend: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub version: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub public_key: String,
    #[serde(default, skip_serializing_if = "is_false")]
    pub encrypted_response_chunks: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attestation: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "JsonNumber::is_zero")]
    pub prefill_tps: JsonNumber,
    #[serde(default, skip_serializing_if = "JsonNumber::is_zero")]
    pub decode_tps: JsonNumber,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub auth_token: String,
    #[serde(default, skip_serializing_if = "is_false")]
    pub private_only: bool,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub apns_device_token: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub apns_environment: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub python_hash: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub runtime_hash: String,
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub template_hashes: std::collections::BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub privacy_capabilities: Option<PrivacyCapabilities>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub protocol_capabilities: Option<ProtocolCapabilities>,
    /// Stable UUID for this provider process lifetime. This is registration
    /// identity, deliberately separate from commutative capabilities.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_process_generation: Option<ProviderProcessGenerationId>,
}

impl Registration {
    /// Rejects a v2 advertisement that cannot fence reconnects to one provider
    /// process generation. Legacy v1 registrations remain valid without it.
    pub fn validate(&self) -> Result<(), ProtocolError> {
        if self
            .protocol_capabilities
            .as_ref()
            .is_some_and(|capabilities| capabilities.protocol_major >= crate::PROTOCOL_V2_MAJOR)
            && self.provider_process_generation.is_none()
        {
            return Err(ProtocolError::MissingProviderProcessGeneration);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HeartbeatStats {
    pub requests_served: u64,
    pub tokens_generated: u64,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub cancellations_received: u64,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub cancellations_before_output: u64,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub cancellations_partial_complete: u64,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub generation_errors_after_output: u64,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub chunk_encryption_errors: u64,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub stream_closed_without_terminal: u64,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub cancel_during_model_load: u64,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub usage_gaps: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SystemMetrics {
    pub memory_pressure: JsonNumber,
    pub cpu_usage: JsonNumber,
    pub thermal_state: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BackendSlotCapacity {
    pub model: String,
    pub state: String,
    pub num_running: u32,
    pub num_waiting: u32,
    #[serde(default, skip_serializing_if = "is_zero_u32")]
    pub max_concurrency: u32,
    pub active_tokens: u64,
    pub max_tokens_potential: u64,
    #[serde(default, skip_serializing_if = "JsonNumber::is_zero")]
    pub observed_decode_tps: JsonNumber,
    #[serde(default, skip_serializing_if = "JsonNumber::is_zero")]
    pub observed_prefill_tps: JsonNumber,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub active_token_budget_used: u64,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub active_token_budget_max: u64,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub queued_token_budget: u64,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub kv_bytes_per_token: u64,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub model_load_time_ms: u64,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub steps_executed: u64,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub admits: u64,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub first_tokens_emitted: u64,
    #[serde(default, skip_serializing_if = "JsonNumber::is_zero")]
    pub seconds_since_last_step: JsonNumber,
    #[serde(default, skip_serializing_if = "JsonNumber::is_zero")]
    pub seconds_since_last_first_token: JsonNumber,
    #[serde(default, skip_serializing_if = "is_false")]
    pub wedge_suspected: bool,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub eval_in_flight_ms: u64,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub idle_clear_in_flight_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BackendCapacity {
    pub slots: Vec<BackendSlotCapacity>,
    pub gpu_memory_active_gb: JsonNumber,
    pub gpu_memory_peak_gb: JsonNumber,
    pub gpu_memory_cache_gb: JsonNumber,
    pub total_memory_gb: JsonNumber,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub free_for_load_gb: Option<JsonNumber>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Heartbeat {
    pub status: String,
    #[serde(default, skip_serializing_if = "OptionalNullable::is_missing")]
    pub active_model: OptionalNullable<String>,
    pub stats: HeartbeatStats,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub warm_models: Vec<String>,
    pub system_metrics: SystemMetrics,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub backend_capacity: Option<BackendCapacity>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub apns_device_token: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub apns_environment: String,
}

pub type RegisterMessage = Registration;
pub type HeartbeatMessage = Heartbeat;
pub type CPUCores = CpuCores;

const fn is_false(value: &bool) -> bool {
    !*value
}

const fn is_zero_u32(value: &u32) -> bool {
    *value == 0
}

const fn is_zero_u64(value: &u64) -> bool {
    *value == 0
}
