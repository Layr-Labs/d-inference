//! Wire protocol message types for provider-coordinator communication.
//!
//! All messages are JSON-encoded and sent over WebSocket. The `type` field
//! (serialized via serde's `tag` attribute) serves as the discriminator
//! for deserialization.
//!
//! Provider -> Coordinator messages:
//!   - Register: Initial registration with hardware, models, and attestation
//!   - Heartbeat: Periodic status update (idle/serving) with stats
//!   - InferenceResponseChunk: Single SSE data line from the backend
//!   - InferenceComplete: Inference finished, includes token usage
//!   - InferenceError: Inference failed, includes error and status code
//!   - AttestationResponse: Response to a challenge with signed nonce
//!
//! Coordinator -> Provider messages:
//!   - InferenceRequest: Run inference with the given body (model, messages)
//!   - Cancel: Cancel an in-flight inference request
//!   - AttestationChallenge: Prove you still hold your key by signing a nonce

use crate::hardware::{HardwareInfo, SystemMetrics};
use crate::models::ModelInfo;
use serde::{Deserialize, Serialize};

/// Messages sent from provider to coordinator.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ProviderMessage {
    Register {
        hardware: HardwareInfo,
        models: Vec<ModelInfo>,
        backend: String,
        /// Provider binary version (e.g. "0.2.31"). Used by coordinator for
        /// minimum version enforcement — providers below the cutoff are excluded.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        version: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        public_key: Option<String>,
        /// Ethereum-format hex wallet address for Tempo blockchain payouts (pathUSD).
        #[serde(skip_serializing_if = "Option::is_none")]
        wallet_address: Option<String>,
        /// Signed Secure Enclave attestation blob (raw JSON from Swift CLI tool).
        /// Uses RawValue to preserve exact byte encoding from Swift's JSONEncoder,
        /// which is critical for signature verification.
        #[serde(skip_serializing_if = "Option::is_none")]
        attestation: Option<Box<serde_json::value::RawValue>>,
        /// Benchmark: prefill tokens per second.
        #[serde(skip_serializing_if = "Option::is_none")]
        prefill_tps: Option<f64>,
        /// Benchmark: decode tokens per second.
        #[serde(skip_serializing_if = "Option::is_none")]
        decode_tps: Option<f64>,
        /// Device-linked provider token (from `darkbloom login`).
        /// When present, the coordinator links this provider to the token's account.
        #[serde(skip_serializing_if = "Option::is_none")]
        auth_token: Option<String>,
        /// SHA-256 hash of the Python interpreter binary.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        python_hash: Option<String>,
        /// Combined SHA-256 hash of all .py files in the vllm_mlx package (sorted).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        runtime_hash: Option<String>,
        /// Per-file SHA-256 hashes of Jinja templates.
        #[serde(default, skip_serializing_if = "std::collections::HashMap::is_empty")]
        template_hashes: std::collections::HashMap<String, String>,
        /// SHA-256 hash of the gRPCServerCLI binary (image generation).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        grpc_binary_hash: Option<String>,
        /// Combined SHA-256 hash of image bridge Python source files.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        image_bridge_hash: Option<String>,
    },
    Heartbeat {
        status: ProviderStatus,
        #[serde(skip_serializing_if = "Option::is_none")]
        active_model: Option<String>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        warm_models: Vec<String>,
        stats: ProviderStats,
        system_metrics: SystemMetrics,
        /// Live backend capacity reported from polling vllm-mlx /v1/status endpoints.
        /// None for providers that don't support capacity reporting (backward compat).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        backend_capacity: Option<BackendCapacity>,
    },
    InferenceAccepted {
        request_id: String,
    },
    InferenceResponseChunk {
        request_id: String,
        data: String,
    },
    InferenceComplete {
        request_id: String,
        usage: UsageInfo,
        /// SE signature over SHA-256(request_id || completion_tokens || response_hash).
        /// Consumers can verify this against the provider's SE public key.
        #[serde(skip_serializing_if = "Option::is_none")]
        se_signature: Option<String>,
        /// SHA-256 hash of all response content (for signature verification).
        #[serde(skip_serializing_if = "Option::is_none")]
        response_hash: Option<String>,
    },
    InferenceError {
        request_id: String,
        error: String,
        status_code: u16,
    },
    /// Transcription result — full text and optional segments.
    TranscriptionComplete {
        request_id: String,
        text: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        segments: Option<Vec<TranscriptionSegment>>,
        #[serde(skip_serializing_if = "Option::is_none")]
        language: Option<String>,
        usage: TranscriptionUsage,
        /// Processing time in seconds.
        duration_secs: f64,
    },
    /// Image generation complete — images were uploaded via HTTP, this just carries metadata.
    ImageGenerationComplete {
        request_id: String,
        usage: ImageGenerationUsage,
        /// Processing time in seconds.
        duration_secs: f64,
    },
    /// Embedding result from a small-tier provider (compute-bound, low-RAM-friendly).
    /// Vectors travel inline because they are small (1024–4096 dims × 4 bytes × N inputs
    /// is well under the 10 MB WebSocket frame limit for typical N ≤ 64).
    EmbeddingComplete {
        request_id: String,
        model: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        data: Vec<EmbeddingVector>,
        usage: EmbeddingUsage,
        duration_secs: f64,
        /// When the request was E2E-encrypted, the provider may also encrypt the
        /// data array back to the coordinator using the session key. When set,
        /// `data` should be empty.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        encrypted_data: Option<EncryptedPayload>,
    },
    /// Cross-encoder rerank result.
    RerankComplete {
        request_id: String,
        model: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        results: Vec<RerankResult>,
        usage: RerankUsage,
        duration_secs: f64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        encrypted_data: Option<EncryptedPayload>,
    },
    /// Response to an attestation challenge from the coordinator.
    /// Includes a fresh SIP status check — the coordinator verifies this
    /// hasn't changed since registration.
    AttestationResponse {
        nonce: String,
        signature: String,
        public_key: String,
        /// Fresh hypervisor status at time of challenge response.
        /// When true, inference memory is hardware-isolated via Stage 2
        /// page tables — RDMA cannot access it even if enabled.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        hypervisor_active: Option<bool>,
        /// Fresh RDMA status at time of challenge response.
        /// If false (RDMA enabled) without hypervisor, coordinator
        /// should mark provider untrusted.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        rdma_disabled: Option<bool>,
        /// Fresh SIP status at time of challenge response.
        /// If false, coordinator should mark provider untrusted.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sip_enabled: Option<bool>,
        /// Fresh Secure Boot status at time of challenge response.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        secure_boot_enabled: Option<bool>,
        /// Fresh SHA-256 hash of the provider binary (re-computed each challenge).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        binary_hash: Option<String>,
        /// SHA-256 weight fingerprint of the currently loaded model (cached at load time).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        active_model_hash: Option<String>,
        /// SHA-256 hash of the Python interpreter binary.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        python_hash: Option<String>,
        /// Combined SHA-256 hash of all .py files in the vllm_mlx package (sorted).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        runtime_hash: Option<String>,
        /// Per-file SHA-256 hashes of Jinja templates.
        #[serde(default, skip_serializing_if = "std::collections::HashMap::is_empty")]
        template_hashes: std::collections::HashMap<String, String>,
        /// SHA-256 hash of the gRPCServerCLI binary (image generation).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        grpc_binary_hash: Option<String>,
        /// Combined SHA-256 hash of image bridge Python source files.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        image_bridge_hash: Option<String>,
        /// Per-model weight hashes: model_id → SHA-256 of weight files.
        /// Covers all active models (text, STT, image).
        #[serde(default, skip_serializing_if = "std::collections::HashMap::is_empty")]
        model_hashes: std::collections::HashMap<String, String>,
    },
}

/// Messages sent from coordinator to provider.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum CoordinatorMessage {
    InferenceRequest {
        request_id: String,
        #[serde(default)]
        body: serde_json::Value,
        /// E2E encrypted request body — only the hardened process can decrypt
        #[serde(default, skip_serializing_if = "Option::is_none")]
        encrypted_body: Option<EncryptedPayload>,
    },
    /// Transcription request — provider should transcribe the audio data.
    TranscriptionRequest {
        request_id: String,
        #[serde(default)]
        body: serde_json::Value,
        /// E2E encrypted transcription body — same encryption as inference requests
        #[serde(default, skip_serializing_if = "Option::is_none")]
        encrypted_body: Option<EncryptedPayload>,
    },
    /// Image generation request — provider should generate images from prompt.
    /// Images are uploaded to upload_url via HTTP POST (not sent over WebSocket).
    ImageGenerationRequest {
        request_id: String,
        /// HTTP URL where the provider should POST generated image bytes.
        #[serde(default)]
        upload_url: String,
        #[serde(default)]
        body: serde_json::Value,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        encrypted_body: Option<EncryptedPayload>,
    },
    /// Embedding request — disaggregated compute job for small-tier providers.
    /// Body matches OpenAI /v1/embeddings (model, input, encoding_format, dimensions).
    EmbeddingRequest {
        request_id: String,
        #[serde(default)]
        body: serde_json::Value,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        encrypted_body: Option<EncryptedPayload>,
    },
    /// Rerank request — disaggregated compute job for small-tier providers.
    /// Body matches Cohere /v1/rerank (model, query, documents, top_n, return_documents).
    RerankRequest {
        request_id: String,
        #[serde(default)]
        body: serde_json::Value,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        encrypted_body: Option<EncryptedPayload>,
    },
    Cancel {
        request_id: String,
    },
    /// Attestation challenge — provider must sign nonce+timestamp and respond.
    AttestationChallenge {
        nonce: String,
        timestamp: String,
    },
    /// Runtime integrity verification result from the coordinator.
    /// Sent after registration or attestation response when the coordinator
    /// has checked the provider's runtime hashes against known-good values.
    RuntimeStatus {
        verified: bool,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        mismatches: Vec<RuntimeMismatch>,
    },
}

/// Body of a transcription request from the coordinator.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TranscriptionRequestBody {
    pub model: String,
    /// Base64-encoded audio data.
    pub audio: String,
    /// ISO 639-1 language code (e.g. "en"). Optional — model may auto-detect.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    /// Audio format hint: "mp3", "wav", "webm", etc.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub format: String,
}

/// NaCl Box encrypted payload for E2E encryption.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct EncryptedPayload {
    /// Sender's ephemeral X25519 public key (base64)
    pub ephemeral_public_key: String,
    /// Nonce + encrypted data (base64)
    pub ciphertext: String,
}

/// A single runtime component whose hash doesn't match the coordinator's known-good value.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RuntimeMismatch {
    /// Component name (e.g. "python", "vllm_mlx", "template:chatml").
    pub component: String,
    /// The hash the coordinator expected.
    pub expected: String,
    /// The hash the provider reported.
    pub got: String,
}

/// PartialEq via serialized JSON — needed because Box<RawValue> (in Register's
/// attestation field) doesn't implement PartialEq directly.
impl PartialEq for ProviderMessage {
    fn eq(&self, other: &Self) -> bool {
        let a = serde_json::to_string(self).unwrap_or_default();
        let b = serde_json::to_string(other).unwrap_or_default();
        a == b
    }
}

/// Capacity state of a single backend slot (one vllm-mlx instance serving one model).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BackendSlotCapacity {
    /// Model ID for this slot.
    pub model: String,
    /// Backend state: "running", "idle_shutdown", "crashed", "reloading".
    pub state: String,
    /// Requests actively generating tokens.
    pub num_running: u32,
    /// Requests queued in the backend scheduler.
    pub num_waiting: u32,
    /// Sum of (prompt_tokens + completion_tokens) across running requests.
    pub active_tokens: i64,
    /// Sum of max_tokens across running requests (worst-case future growth).
    pub max_tokens_potential: i64,
}

/// Aggregate backend capacity across all slots on a provider. Reported in
/// heartbeats so the coordinator can make routing decisions based on actual
/// GPU utilization rather than hardcoded concurrency limits.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BackendCapacity {
    /// Per-model slot capacity.
    pub slots: Vec<BackendSlotCapacity>,
    /// Metal active memory in GB (shared across all slots).
    pub gpu_memory_active_gb: f64,
    /// Metal peak memory in GB.
    pub gpu_memory_peak_gb: f64,
    /// Metal cache memory in GB (reclaimable).
    pub gpu_memory_cache_gb: f64,
    /// Total system/GPU memory in GB.
    pub total_memory_gb: f64,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum ProviderStatus {
    Idle,
    Serving,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ProviderStats {
    pub requests_served: u64,
    pub tokens_generated: u64,
}

impl Default for ProviderStats {
    fn default() -> Self {
        Self {
            requests_served: 0,
            tokens_generated: 0,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct UsageInfo {
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
}

/// A timed segment within a transcription result.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TranscriptionSegment {
    pub start: f64,
    pub end: f64,
    pub text: String,
}

/// Usage info for billing STT requests.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TranscriptionUsage {
    pub audio_seconds: f64,
    pub generation_tokens: u64,
}

/// Body of an image generation request from the coordinator.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ImageGenerationRequestBody {
    pub model: String,
    pub prompt: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub negative_prompt: Option<String>,
    #[serde(default = "default_image_count")]
    pub n: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub steps: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub seed: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub response_format: Option<String>,
}

fn default_image_count() -> u32 {
    1
}

/// A single generated image in base64 format.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ImageDataPayload {
    pub b64_json: String,
}

/// Usage info for billing image generation requests.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ImageGenerationUsage {
    pub images_generated: u32,
    pub width: u32,
    pub height: u32,
    pub steps: u32,
    pub model: String,
}

// ---------------------------------------------------------------------------
// Disaggregated compute: embeddings + reranking
// ---------------------------------------------------------------------------

/// Body of an embedding request from the coordinator.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EmbeddingRequestBody {
    pub model: String,
    /// `input` may be a string or an array of strings (or token-id arrays).
    /// We keep it as a generic Value so the local backend gets it verbatim.
    pub input: serde_json::Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub encoding_format: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dimensions: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
}

/// One (input → vector) entry in an embedding result.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct EmbeddingVector {
    pub index: u32,
    pub embedding: Vec<f32>,
}

/// Usage info for billing embedding requests.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub struct EmbeddingUsage {
    pub prompt_tokens: u64,
    pub total_tokens: u64,
}

/// Body of a rerank request from the coordinator.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RerankRequestBody {
    pub model: String,
    pub query: String,
    pub documents: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub top_n: Option<u32>,
    #[serde(default)]
    pub return_documents: bool,
}

/// One (document, score) pair in a rerank result, sorted descending by score.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RerankResult {
    pub index: u32,
    pub relevance_score: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub document: Option<String>,
}

/// Usage info for billing rerank requests.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub struct RerankUsage {
    pub prompt_tokens: u64,
    pub total_tokens: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_hardware() -> HardwareInfo {
        use crate::hardware::{ChipFamily, ChipTier, CpuCores};
        HardwareInfo {
            machine_model: "Mac16,1".to_string(),
            chip_name: "Apple M4 Max".to_string(),
            chip_family: ChipFamily::M4,
            chip_tier: ChipTier::Max,
            memory_gb: 128,
            memory_available_gb: 124,
            cpu_cores: CpuCores {
                total: 16,
                performance: 12,
                efficiency: 4,
            },
            gpu_cores: 40,
            memory_bandwidth_gbs: 546,
        }
    }

    #[test]
    fn test_register_message_roundtrip() {
        let msg = ProviderMessage::Register {
            hardware: sample_hardware(),
            models: vec![ModelInfo {
                id: "mlx-community/Qwen2.5-7B-4bit".to_string(),
                model_type: Some("qwen2".to_string()),
                parameters: None,
                quantization: Some("4bit".to_string()),
                size_bytes: 4_000_000_000,
                estimated_memory_gb: 4.5,
                weight_hash: None,
            }],
            backend: "vllm_mlx".to_string(),
            version: None,
            public_key: None,
            wallet_address: None,
            attestation: None,
            prefill_tps: None,
            decode_tps: None,
            auth_token: None,
            python_hash: None,
            runtime_hash: None,
            template_hashes: std::collections::HashMap::new(),
            grpc_binary_hash: None,
            image_bridge_hash: None,
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"register\""));
        // wallet_address should be omitted when None
        assert!(!json.contains("wallet_address"));
        // attestation should be omitted when None
        assert!(!json.contains("attestation"));
        // benchmark fields should be omitted when None
        assert!(!json.contains("prefill_tps"));
        assert!(!json.contains("decode_tps"));
        // runtime hash fields should be omitted when empty
        assert!(!json.contains("python_hash"));
        assert!(!json.contains("runtime_hash"));
        assert!(!json.contains("template_hashes"));
        let deserialized: ProviderMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, deserialized);
    }

    #[test]
    fn test_register_message_with_wallet_address() {
        let msg = ProviderMessage::Register {
            hardware: sample_hardware(),
            models: vec![ModelInfo {
                id: "mlx-community/Qwen2.5-7B-4bit".to_string(),
                model_type: Some("qwen2".to_string()),
                parameters: None,
                quantization: Some("4bit".to_string()),
                size_bytes: 4_000_000_000,
                estimated_memory_gb: 4.5,
                weight_hash: None,
            }],
            backend: "vllm_mlx".to_string(),
            version: None,
            public_key: None,
            wallet_address: Some("0x1234567890abcdef1234567890abcdef12345678".to_string()),
            attestation: None,
            prefill_tps: None,
            decode_tps: None,
            auth_token: None,
            python_hash: None,
            runtime_hash: None,
            template_hashes: std::collections::HashMap::new(),
            grpc_binary_hash: None,
            image_bridge_hash: None,
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"wallet_address\":\"0x1234567890abcdef1234567890abcdef12345678\""));
        let deserialized: ProviderMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, deserialized);
    }

    #[test]
    fn test_register_message_with_attestation() {
        let attestation_str = r#"{"attestation":{"chipName":"Apple M3 Max","hardwareModel":"Mac15,8","osVersion":"15.3.0","publicKey":"dGVzdA==","secureBootEnabled":true,"secureEnclaveAvailable":true,"sipEnabled":true,"timestamp":"2025-01-01T00:00:00Z"},"signature":"dGVzdHNpZw=="}"#;
        let attestation_raw: Box<serde_json::value::RawValue> =
            serde_json::from_str(attestation_str).unwrap();

        let msg = ProviderMessage::Register {
            hardware: sample_hardware(),
            models: vec![ModelInfo {
                id: "mlx-community/Qwen2.5-7B-4bit".to_string(),
                model_type: Some("qwen2".to_string()),
                parameters: None,
                quantization: Some("4bit".to_string()),
                size_bytes: 4_000_000_000,
                estimated_memory_gb: 4.5,
                weight_hash: None,
            }],
            backend: "vllm_mlx".to_string(),
            version: None,
            public_key: Some("c29tZWtleQ==".to_string()),
            wallet_address: None,
            attestation: Some(attestation_raw),
            prefill_tps: Some(500.0),
            decode_tps: Some(100.0),
            auth_token: None,
            python_hash: None,
            runtime_hash: None,
            template_hashes: std::collections::HashMap::new(),
            grpc_binary_hash: None,
            image_bridge_hash: None,
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"attestation\""));
        assert!(json.contains("\"signature\""));
        assert!(json.contains("\"prefill_tps\":500.0"));
        assert!(json.contains("\"decode_tps\":100.0"));
        // Note: full ProviderMessage roundtrip with RawValue doesn't work
        // due to serde's internally-tagged enum buffering. The Register
        // message is deserialized on the Go coordinator side, not in Rust.
    }

    #[test]
    fn test_heartbeat_idle_roundtrip() {
        use crate::hardware::{SystemMetrics, ThermalState};
        let msg = ProviderMessage::Heartbeat {
            status: ProviderStatus::Idle,
            active_model: None,
            warm_models: vec![],
            stats: ProviderStats::default(),
            system_metrics: SystemMetrics {
                memory_pressure: 0.0,
                cpu_usage: 0.0,
                thermal_state: ThermalState::Nominal,
            },
            backend_capacity: None,
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"heartbeat\""));
        assert!(json.contains("\"status\":\"idle\""));
        assert!(!json.contains("active_model"));
        let deserialized: ProviderMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, deserialized);
    }

    #[test]
    fn test_heartbeat_serving_roundtrip() {
        use crate::hardware::{SystemMetrics, ThermalState};
        let msg = ProviderMessage::Heartbeat {
            status: ProviderStatus::Serving,
            active_model: Some("qwen3.5-9b".to_string()),
            warm_models: vec![],
            stats: ProviderStats {
                requests_served: 10,
                tokens_generated: 5000,
            },
            system_metrics: SystemMetrics {
                memory_pressure: 0.3,
                cpu_usage: 0.5,
                thermal_state: ThermalState::Nominal,
            },
            backend_capacity: None,
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"heartbeat\""));
        assert!(json.contains("\"status\":\"serving\""));
        assert!(json.contains("\"active_model\":\"qwen3.5-9b\""));
        let deserialized: ProviderMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, deserialized);
    }

    #[test]
    fn test_inference_response_chunk_roundtrip() {
        let msg = ProviderMessage::InferenceResponseChunk {
            request_id: "uuid-123".to_string(),
            data: "data: {\"choices\":[]}".to_string(),
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"inference_response_chunk\""));
        let deserialized: ProviderMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, deserialized);
    }

    #[test]
    fn test_inference_complete_roundtrip() {
        let msg = ProviderMessage::InferenceComplete {
            request_id: "uuid-456".to_string(),
            usage: UsageInfo {
                prompt_tokens: 50,
                completion_tokens: 100,
            },
            se_signature: None,
            response_hash: None,
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"inference_complete\""));
        let deserialized: ProviderMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, deserialized);
    }

    #[test]
    fn test_inference_error_roundtrip() {
        let msg = ProviderMessage::InferenceError {
            request_id: "uuid-789".to_string(),
            error: "model not loaded".to_string(),
            status_code: 500,
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"inference_error\""));
        let deserialized: ProviderMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, deserialized);
    }

    #[test]
    fn test_inference_request_roundtrip() {
        let body = serde_json::json!({
            "model": "qwen3.5-9b",
            "messages": [{"role": "user", "content": "hello"}],
            "stream": true
        });

        let msg = CoordinatorMessage::InferenceRequest {
            request_id: "uuid-abc".to_string(),
            body,
            encrypted_body: None,
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"inference_request\""));
        let deserialized: CoordinatorMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, deserialized);
    }

    #[test]
    fn test_cancel_roundtrip() {
        let msg = CoordinatorMessage::Cancel {
            request_id: "uuid-cancel".to_string(),
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"cancel\""));
        let deserialized: CoordinatorMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, deserialized);
    }

    #[test]
    fn test_provider_stats_default() {
        let stats = ProviderStats::default();
        assert_eq!(stats.requests_served, 0);
        assert_eq!(stats.tokens_generated, 0);
    }

    #[test]
    fn test_deserialize_inference_request_from_json() {
        let raw = r#"{"type":"inference_request","request_id":"abc-123","body":{"model":"test","messages":[{"role":"user","content":"hi"}],"stream":false}}"#;
        let msg: CoordinatorMessage = serde_json::from_str(raw).unwrap();
        match msg {
            CoordinatorMessage::InferenceRequest {
                request_id, body, ..
            } => {
                assert_eq!(request_id, "abc-123");
                assert_eq!(body["model"], "test");
                assert_eq!(body["stream"], false);
            }
            _ => panic!("expected InferenceRequest"),
        }
    }

    #[test]
    fn test_deserialize_cancel_from_json() {
        let raw = r#"{"type":"cancel","request_id":"cancel-456"}"#;
        let msg: CoordinatorMessage = serde_json::from_str(raw).unwrap();
        match msg {
            CoordinatorMessage::Cancel { request_id } => {
                assert_eq!(request_id, "cancel-456");
            }
            _ => panic!("expected Cancel"),
        }
    }

    #[test]
    fn test_attestation_challenge_roundtrip() {
        let msg = CoordinatorMessage::AttestationChallenge {
            nonce: "dGVzdG5vbmNl".to_string(),
            timestamp: "2025-01-15T10:30:00Z".to_string(),
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"attestation_challenge\""));
        assert!(json.contains("\"nonce\":\"dGVzdG5vbmNl\""));
        assert!(json.contains("\"timestamp\":\"2025-01-15T10:30:00Z\""));
        let deserialized: CoordinatorMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, deserialized);
    }

    #[test]
    fn test_attestation_response_roundtrip() {
        let msg = ProviderMessage::AttestationResponse {
            nonce: "dGVzdG5vbmNl".to_string(),
            signature: "c2lnbmF0dXJl".to_string(),
            public_key: "cHVia2V5".to_string(),
            hypervisor_active: Some(true),
            rdma_disabled: Some(true),
            sip_enabled: Some(true),
            secure_boot_enabled: Some(true),
            binary_hash: None,
            active_model_hash: None,
            python_hash: None,
            runtime_hash: None,
            template_hashes: std::collections::HashMap::new(),
            grpc_binary_hash: None,
            image_bridge_hash: None,
            model_hashes: std::collections::HashMap::new(),
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"attestation_response\""));
        assert!(json.contains("\"nonce\":\"dGVzdG5vbmNl\""));
        assert!(json.contains("\"signature\":\"c2lnbmF0dXJl\""));
        assert!(json.contains("\"public_key\":\"cHVia2V5\""));
        let deserialized: ProviderMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, deserialized);
    }

    #[test]
    fn test_heartbeat_system_metrics_roundtrip() {
        use crate::hardware::{SystemMetrics, ThermalState};
        let msg = ProviderMessage::Heartbeat {
            status: ProviderStatus::Idle,
            active_model: None,
            warm_models: vec![],
            stats: ProviderStats::default(),
            system_metrics: SystemMetrics {
                memory_pressure: 0.65,
                cpu_usage: 0.3,
                thermal_state: ThermalState::Nominal,
            },
            backend_capacity: None,
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"system_metrics\""));
        assert!(json.contains("\"memory_pressure\":0.65"));
        assert!(json.contains("\"thermal_state\":\"nominal\""));
        let deserialized: ProviderMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, deserialized);
    }

    #[test]
    fn test_backend_capacity_roundtrip() {
        let cap = BackendCapacity {
            slots: vec![
                BackendSlotCapacity {
                    model: "mlx-community/Qwen2.5-7B-4bit".to_string(),
                    state: "running".to_string(),
                    num_running: 3,
                    num_waiting: 1,
                    active_tokens: 5000,
                    max_tokens_potential: 12000,
                },
                BackendSlotCapacity {
                    model: "mlx-community/Gemma-4-27B-4bit".to_string(),
                    state: "idle_shutdown".to_string(),
                    num_running: 0,
                    num_waiting: 0,
                    active_tokens: 0,
                    max_tokens_potential: 0,
                },
            ],
            gpu_memory_active_gb: 45.2,
            gpu_memory_peak_gb: 52.1,
            gpu_memory_cache_gb: 8.3,
            total_memory_gb: 128.0,
        };

        let json = serde_json::to_string(&cap).unwrap();
        assert!(json.contains("\"num_running\":3"));
        assert!(json.contains("\"idle_shutdown\""));
        assert!(json.contains("\"gpu_memory_active_gb\":45.2"));

        let deserialized: BackendCapacity = serde_json::from_str(&json).unwrap();
        assert_eq!(cap, deserialized);
    }

    #[test]
    fn test_heartbeat_with_backend_capacity_roundtrip() {
        use crate::hardware::{SystemMetrics, ThermalState};
        let msg = ProviderMessage::Heartbeat {
            status: ProviderStatus::Serving,
            active_model: Some("test-model".to_string()),
            warm_models: vec!["test-model".to_string()],
            stats: ProviderStats {
                requests_served: 42,
                tokens_generated: 10000,
            },
            system_metrics: SystemMetrics {
                memory_pressure: 0.3,
                cpu_usage: 0.5,
                thermal_state: ThermalState::Nominal,
            },
            backend_capacity: Some(BackendCapacity {
                slots: vec![BackendSlotCapacity {
                    model: "test-model".to_string(),
                    state: "running".to_string(),
                    num_running: 2,
                    num_waiting: 0,
                    active_tokens: 3000,
                    max_tokens_potential: 8000,
                }],
                gpu_memory_active_gb: 25.5,
                gpu_memory_peak_gb: 30.0,
                gpu_memory_cache_gb: 5.0,
                total_memory_gb: 64.0,
            }),
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"backend_capacity\""));
        assert!(json.contains("\"gpu_memory_active_gb\":25.5"));

        let deserialized: ProviderMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, deserialized);
    }

    #[test]
    fn test_heartbeat_without_capacity_omits_field() {
        use crate::hardware::{SystemMetrics, ThermalState};
        let msg = ProviderMessage::Heartbeat {
            status: ProviderStatus::Idle,
            active_model: None,
            warm_models: vec![],
            stats: ProviderStats::default(),
            system_metrics: SystemMetrics {
                memory_pressure: 0.0,
                cpu_usage: 0.0,
                thermal_state: ThermalState::Nominal,
            },
            backend_capacity: None,
        };

        let json = serde_json::to_string(&msg).unwrap();
        // backend_capacity should be omitted when None (skip_serializing_if)
        assert!(!json.contains("backend_capacity"));

        let deserialized: ProviderMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, deserialized);
    }

    #[test]
    fn test_cross_language_backend_capacity_json() {
        // Verify Rust can parse JSON that Go would produce (snake_case fields)
        let go_json = r#"{"slots":[{"model":"test-model","state":"running","num_running":2,"num_waiting":1,"active_tokens":5000,"max_tokens_potential":12000}],"gpu_memory_active_gb":45.2,"gpu_memory_peak_gb":52.1,"gpu_memory_cache_gb":8.3,"total_memory_gb":128}"#;

        let cap: BackendCapacity = serde_json::from_str(go_json).unwrap();
        assert_eq!(cap.slots.len(), 1);
        assert_eq!(cap.slots[0].num_running, 2);
        assert_eq!(cap.gpu_memory_active_gb, 45.2);
        assert_eq!(cap.total_memory_gb, 128.0);
    }

    #[test]
    fn test_deserialize_attestation_challenge_from_json() {
        let raw = r#"{"type":"attestation_challenge","nonce":"YWJjZGVm","timestamp":"2025-06-01T00:00:00Z"}"#;
        let msg: CoordinatorMessage = serde_json::from_str(raw).unwrap();
        match msg {
            CoordinatorMessage::AttestationChallenge { nonce, timestamp } => {
                assert_eq!(nonce, "YWJjZGVm");
                assert_eq!(timestamp, "2025-06-01T00:00:00Z");
            }
            _ => panic!("expected AttestationChallenge"),
        }
    }

    #[test]
    fn test_transcription_request_roundtrip() {
        let body = serde_json::json!({
            "model": "CohereLabs/cohere-transcribe",
            "audio": "SGVsbG8=",
            "language": "en",
            "format": "wav"
        });
        let msg = CoordinatorMessage::TranscriptionRequest {
            request_id: "stt-123".to_string(),
            body,
            encrypted_body: None,
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"transcription_request\""));
        assert!(json.contains("\"request_id\":\"stt-123\""));
        assert!(json.contains("\"model\":\"CohereLabs/cohere-transcribe\""));
        assert!(json.contains("\"audio\":\"SGVsbG8=\""));
        let deserialized: CoordinatorMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, deserialized);
    }

    #[test]
    fn test_transcription_complete_roundtrip() {
        let msg = ProviderMessage::TranscriptionComplete {
            request_id: "stt-456".to_string(),
            text: "Hello world".to_string(),
            segments: Some(vec![TranscriptionSegment {
                start: 0.0,
                end: 5.0,
                text: "Hello world".to_string(),
            }]),
            language: Some("en".to_string()),
            usage: TranscriptionUsage {
                audio_seconds: 5.0,
                generation_tokens: 10,
            },
            duration_secs: 0.5,
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"transcription_complete\""));
        assert!(json.contains("\"text\":\"Hello world\""));
        assert!(json.contains("\"audio_seconds\":5.0"));
        assert!(json.contains("\"duration_secs\":0.5"));
        let deserialized: ProviderMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, deserialized);
    }

    #[test]
    fn test_deserialize_transcription_request_from_go_json() {
        // This is the JSON format that Go coordinator would produce (plaintext)
        let raw = r#"{"type":"transcription_request","request_id":"go-req-1","body":{"model":"cohere-transcribe","audio":"dGVzdA==","language":"en","format":"mp3"}}"#;
        let msg: CoordinatorMessage = serde_json::from_str(raw).unwrap();
        match msg {
            CoordinatorMessage::TranscriptionRequest {
                request_id,
                body,
                encrypted_body,
            } => {
                assert_eq!(request_id, "go-req-1");
                assert_eq!(body["model"], "cohere-transcribe");
                assert_eq!(body["audio"], "dGVzdA==");
                assert!(encrypted_body.is_none());
            }
            _ => panic!("expected TranscriptionRequest"),
        }
    }

    #[test]
    fn test_deserialize_transcription_request_encrypted() {
        // When E2E encrypted, body is empty and encrypted_body is present
        let raw = r#"{"type":"transcription_request","request_id":"enc-1","encrypted_body":{"ephemeral_public_key":"a2V5","ciphertext":"Y2lwaGVy"}}"#;
        let msg: CoordinatorMessage = serde_json::from_str(raw).unwrap();
        match msg {
            CoordinatorMessage::TranscriptionRequest {
                request_id,
                encrypted_body,
                ..
            } => {
                assert_eq!(request_id, "enc-1");
                let enc = encrypted_body.unwrap();
                assert_eq!(enc.ephemeral_public_key, "a2V5");
                assert_eq!(enc.ciphertext, "Y2lwaGVy");
            }
            _ => panic!("expected TranscriptionRequest"),
        }
    }

    #[test]
    fn test_image_generation_request_roundtrip() {
        let body = serde_json::json!({
            "model": "flux-klein-4b",
            "prompt": "a cat wearing a hat",
            "n": 1,
            "size": "1024x1024"
        });
        let msg = CoordinatorMessage::ImageGenerationRequest {
            request_id: "img-123".to_string(),
            upload_url: "https://example.com/v1/provider/image-upload?request_id=img-123"
                .to_string(),
            body,
            encrypted_body: None,
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"image_generation_request\""));
        assert!(json.contains("\"request_id\":\"img-123\""));
        assert!(json.contains("\"upload_url\""));
        assert!(json.contains("\"prompt\":\"a cat wearing a hat\""));
        let deserialized: CoordinatorMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, deserialized);
    }

    #[test]
    fn test_image_generation_complete_roundtrip() {
        // Complete message carries only usage metadata — images uploaded via HTTP
        let msg = ProviderMessage::ImageGenerationComplete {
            request_id: "img-456".to_string(),
            usage: ImageGenerationUsage {
                images_generated: 1,
                width: 1024,
                height: 1024,
                steps: 4,
                model: "flux-klein-4b".to_string(),
            },
            duration_secs: 7.5,
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"image_generation_complete\""));
        assert!(json.contains("\"images_generated\":1"));
        assert!(json.contains("\"duration_secs\":7.5"));
        // No images field — they're uploaded via HTTP
        assert!(!json.contains("b64_json"));
        let deserialized: ProviderMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, deserialized);
    }

    #[test]
    fn test_deserialize_image_generation_request_from_go_json() {
        let raw = r#"{"type":"image_generation_request","request_id":"go-img-1","upload_url":"https://example.com/upload","body":{"model":"flux-klein-4b","prompt":"sunset over mountains","n":2,"size":"512x512"}}"#;
        let msg: CoordinatorMessage = serde_json::from_str(raw).unwrap();
        match msg {
            CoordinatorMessage::ImageGenerationRequest {
                request_id,
                upload_url,
                body,
                encrypted_body,
            } => {
                assert_eq!(request_id, "go-img-1");
                assert_eq!(upload_url, "https://example.com/upload");
                assert_eq!(body["model"], "flux-klein-4b");
                assert_eq!(body["prompt"], "sunset over mountains");
                assert_eq!(body["n"], 2);
                assert!(encrypted_body.is_none());
            }
            _ => panic!("expected ImageGenerationRequest"),
        }
    }

    #[test]
    fn test_deserialize_image_generation_request_encrypted() {
        let raw = r#"{"type":"image_generation_request","request_id":"enc-img-1","upload_url":"https://example.com/upload","encrypted_body":{"ephemeral_public_key":"a2V5","ciphertext":"Y2lwaGVy"}}"#;
        let msg: CoordinatorMessage = serde_json::from_str(raw).unwrap();
        match msg {
            CoordinatorMessage::ImageGenerationRequest {
                request_id,
                encrypted_body,
                ..
            } => {
                assert_eq!(request_id, "enc-img-1");
                let enc = encrypted_body.unwrap();
                assert_eq!(enc.ephemeral_public_key, "a2V5");
                assert_eq!(enc.ciphertext, "Y2lwaGVy");
            }
            _ => panic!("expected ImageGenerationRequest"),
        }
    }

    // -----------------------------------------------------------------------
    // Go-format JSON deserialization tests — simulating coordinator messages
    // -----------------------------------------------------------------------

    #[test]
    fn test_deserialize_go_inference_request_with_encrypted_body() {
        // Simulates what the Go coordinator sends when E2E encryption is enabled:
        // body is null/empty, encrypted_body carries the NaCl Box payload.
        let raw = r#"{
            "type": "inference_request",
            "request_id": "go-enc-req-1",
            "body": null,
            "encrypted_body": {
                "ephemeral_public_key": "dGVzdGVwaGVtZXJhbHB1YmxpY2tleWJ5dGVzMTI=",
                "ciphertext": "bm9uY2UyNGJ5dGVzaGVyZTEyMzRjaXBoZXJ0ZXh0ZGF0YQ=="
            }
        }"#;
        let msg: CoordinatorMessage = serde_json::from_str(raw).unwrap();
        match msg {
            CoordinatorMessage::InferenceRequest {
                request_id,
                body,
                encrypted_body,
            } => {
                assert_eq!(request_id, "go-enc-req-1");
                assert!(body.is_null(), "body should be null when encrypted");
                let enc = encrypted_body.expect("encrypted_body should be present");
                assert_eq!(
                    enc.ephemeral_public_key,
                    "dGVzdGVwaGVtZXJhbHB1YmxpY2tleWJ5dGVzMTI="
                );
                assert_eq!(
                    enc.ciphertext,
                    "bm9uY2UyNGJ5dGVzaGVyZTEyMzRjaXBoZXJ0ZXh0ZGF0YQ=="
                );
            }
            _ => panic!("expected InferenceRequest"),
        }
    }

    #[test]
    fn test_deserialize_go_attestation_challenge() {
        // Exact JSON format the Go coordinator sends for attestation challenges.
        let raw = r#"{"type":"attestation_challenge","nonce":"cmFuZG9tLW5vbmNlLWJ5dGVz","timestamp":"2026-04-03T12:00:00Z"}"#;
        let msg: CoordinatorMessage = serde_json::from_str(raw).unwrap();
        match msg {
            CoordinatorMessage::AttestationChallenge { nonce, timestamp } => {
                assert_eq!(nonce, "cmFuZG9tLW5vbmNlLWJ5dGVz");
                assert_eq!(timestamp, "2026-04-03T12:00:00Z");
            }
            _ => panic!("expected AttestationChallenge"),
        }
    }

    #[test]
    fn test_deserialize_go_cancel() {
        let raw = r#"{"type":"cancel","request_id":"req-to-cancel-42"}"#;
        let msg: CoordinatorMessage = serde_json::from_str(raw).unwrap();
        match msg {
            CoordinatorMessage::Cancel { request_id } => {
                assert_eq!(request_id, "req-to-cancel-42");
            }
            _ => panic!("expected Cancel"),
        }
    }

    #[test]
    fn test_deserialize_go_inference_request_with_all_fields() {
        // Full inference request as the Go coordinator would emit (no encryption,
        // all OpenAI-compatible body fields present).
        let raw = r#"{
            "type": "inference_request",
            "request_id": "uuid-full-1",
            "body": {
                "model": "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit",
                "messages": [
                    {"role": "system", "content": "You are a helpful assistant."},
                    {"role": "user", "content": "Write a hello world in Rust."}
                ],
                "stream": true,
                "temperature": 0.7,
                "max_tokens": 2048,
                "top_p": 0.9
            }
        }"#;
        let msg: CoordinatorMessage = serde_json::from_str(raw).unwrap();
        match msg {
            CoordinatorMessage::InferenceRequest {
                request_id,
                body,
                encrypted_body,
            } => {
                assert_eq!(request_id, "uuid-full-1");
                assert!(encrypted_body.is_none());
                assert_eq!(
                    body["model"],
                    "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit"
                );
                assert_eq!(body["stream"], true);
                assert_eq!(body["temperature"], 0.7);
                assert_eq!(body["max_tokens"], 2048);
                let messages = body["messages"].as_array().unwrap();
                assert_eq!(messages.len(), 2);
                assert_eq!(messages[0]["role"], "system");
                assert_eq!(messages[1]["role"], "user");
            }
            _ => panic!("expected InferenceRequest"),
        }
    }

    // -----------------------------------------------------------------------
    // Comprehensive ProviderMessage variant round-trip tests
    // -----------------------------------------------------------------------

    #[test]
    fn test_all_provider_message_variants_roundtrip() {
        use crate::hardware::{SystemMetrics, ThermalState};

        let messages: Vec<ProviderMessage> = vec![
            // Register (minimal)
            ProviderMessage::Register {
                hardware: sample_hardware(),
                models: vec![],
                backend: "vllm_mlx".to_string(),
                version: None,
                public_key: None,
                wallet_address: None,
                attestation: None,
                prefill_tps: None,
                decode_tps: None,
                auth_token: None,
                python_hash: None,
                runtime_hash: None,
                template_hashes: std::collections::HashMap::new(),
                grpc_binary_hash: None,
                image_bridge_hash: None,
            },
            // Heartbeat (idle)
            ProviderMessage::Heartbeat {
                status: ProviderStatus::Idle,
                active_model: None,
                warm_models: vec![],
                stats: ProviderStats::default(),
                system_metrics: SystemMetrics {
                    memory_pressure: 0.0,
                    cpu_usage: 0.0,
                    thermal_state: ThermalState::Nominal,
                },
                backend_capacity: None,
            },
            // Heartbeat (serving)
            ProviderMessage::Heartbeat {
                status: ProviderStatus::Serving,
                active_model: Some("test-model".to_string()),
                warm_models: vec![],
                stats: ProviderStats {
                    requests_served: 42,
                    tokens_generated: 10000,
                },
                system_metrics: SystemMetrics {
                    memory_pressure: 0.8,
                    cpu_usage: 0.95,
                    thermal_state: ThermalState::Serious,
                },
                backend_capacity: None,
            },
            // InferenceResponseChunk
            ProviderMessage::InferenceResponseChunk {
                request_id: "req-1".to_string(),
                data: "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}".to_string(),
            },
            // InferenceComplete
            ProviderMessage::InferenceComplete {
                request_id: "req-1".to_string(),
                usage: UsageInfo {
                    prompt_tokens: 25,
                    completion_tokens: 150,
                },
                se_signature: Some("c2lnbmF0dXJl".to_string()),
                response_hash: Some("aGFzaA==".to_string()),
            },
            // InferenceError
            ProviderMessage::InferenceError {
                request_id: "req-2".to_string(),
                error: "out of memory".to_string(),
                status_code: 503,
            },
            // AttestationResponse
            ProviderMessage::AttestationResponse {
                nonce: "bm9uY2U=".to_string(),
                signature: "c2ln".to_string(),
                public_key: "cGs=".to_string(),
                hypervisor_active: Some(false),
                rdma_disabled: Some(true),
                sip_enabled: Some(true),
                secure_boot_enabled: Some(true),
                binary_hash: None,
                active_model_hash: None,
                python_hash: None,
                runtime_hash: None,
                template_hashes: std::collections::HashMap::new(),
                grpc_binary_hash: None,
                image_bridge_hash: None,
                model_hashes: std::collections::HashMap::new(),
            },
        ];

        for msg in &messages {
            let json = serde_json::to_string(msg).unwrap();
            let deserialized: ProviderMessage = serde_json::from_str(&json).unwrap();
            assert_eq!(msg, &deserialized, "Round-trip failed for: {json}");
        }
    }

    #[test]
    fn test_all_coordinator_message_variants_roundtrip() {
        let messages: Vec<CoordinatorMessage> = vec![
            CoordinatorMessage::InferenceRequest {
                request_id: "r1".to_string(),
                body: serde_json::json!({"model": "test", "messages": [], "stream": true}),
                encrypted_body: None,
            },
            CoordinatorMessage::InferenceRequest {
                request_id: "r2".to_string(),
                body: serde_json::Value::Null,
                encrypted_body: Some(EncryptedPayload {
                    ephemeral_public_key: "ZXBoZW1lcmFs".to_string(),
                    ciphertext: "Y2lwaGVy".to_string(),
                }),
            },
            CoordinatorMessage::TranscriptionRequest {
                request_id: "t1".to_string(),
                body: serde_json::json!({"model": "whisper", "audio": "YXVkaW8="}),
                encrypted_body: None,
            },
            CoordinatorMessage::ImageGenerationRequest {
                request_id: "i1".to_string(),
                upload_url: "https://example.com/upload".to_string(),
                body: serde_json::json!({"model": "flux", "prompt": "a cat"}),
                encrypted_body: None,
            },
            CoordinatorMessage::Cancel {
                request_id: "c1".to_string(),
            },
            CoordinatorMessage::AttestationChallenge {
                nonce: "bm9uY2U=".to_string(),
                timestamp: "2026-01-01T00:00:00Z".to_string(),
            },
            CoordinatorMessage::RuntimeStatus {
                verified: true,
                mismatches: vec![],
            },
            CoordinatorMessage::RuntimeStatus {
                verified: false,
                mismatches: vec![RuntimeMismatch {
                    component: "python".to_string(),
                    expected: "abc123".to_string(),
                    got: "def456".to_string(),
                }],
            },
        ];

        for msg in &messages {
            let json = serde_json::to_string(msg).unwrap();
            let deserialized: CoordinatorMessage = serde_json::from_str(&json).unwrap();
            assert_eq!(msg, &deserialized, "Round-trip failed for: {json}");
        }
    }

    #[test]
    fn test_encrypted_payload_serialization() {
        let payload = EncryptedPayload {
            ephemeral_public_key: "dGVzdC1rZXk=".to_string(),
            ciphertext: "dGVzdC1jaXBoZXI=".to_string(),
        };

        let json = serde_json::to_string(&payload).unwrap();
        assert!(json.contains("\"ephemeral_public_key\""));
        assert!(json.contains("\"ciphertext\""));

        let deserialized: EncryptedPayload = serde_json::from_str(&json).unwrap();
        assert_eq!(payload, deserialized);
    }

    #[test]
    fn test_coordinator_message_unknown_type_fails() {
        let raw = r#"{"type":"unknown_message_type","foo":"bar"}"#;
        let result = serde_json::from_str::<CoordinatorMessage>(raw);
        assert!(
            result.is_err(),
            "Unknown message type should fail deserialization"
        );
    }

    #[test]
    fn test_inference_complete_with_se_signature_roundtrip() {
        let msg = ProviderMessage::InferenceComplete {
            request_id: "signed-req".to_string(),
            usage: UsageInfo {
                prompt_tokens: 100,
                completion_tokens: 500,
            },
            se_signature: Some("MEUCIQD...base64sig...".to_string()),
            response_hash: Some("abc123def456".to_string()),
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"se_signature\""));
        assert!(json.contains("\"response_hash\""));
        let deserialized: ProviderMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, deserialized);
    }

    #[test]
    fn test_runtime_status_verified_roundtrip() {
        let msg = CoordinatorMessage::RuntimeStatus {
            verified: true,
            mismatches: vec![],
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"runtime_status\""));
        assert!(json.contains("\"verified\":true"));
        // Empty mismatches should be omitted
        assert!(!json.contains("mismatches"));
        let deserialized: CoordinatorMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, deserialized);
    }

    #[test]
    fn test_runtime_status_with_mismatches_roundtrip() {
        let msg = CoordinatorMessage::RuntimeStatus {
            verified: false,
            mismatches: vec![
                RuntimeMismatch {
                    component: "python".to_string(),
                    expected: "abc123".to_string(),
                    got: "def456".to_string(),
                },
                RuntimeMismatch {
                    component: "template:chatml".to_string(),
                    expected: "111".to_string(),
                    got: "222".to_string(),
                },
            ],
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"verified\":false"));
        assert!(json.contains("\"mismatches\""));
        assert!(json.contains("\"component\":\"python\""));
        let deserialized: CoordinatorMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, deserialized);
    }

    #[test]
    fn test_embedding_request_from_go_json_encrypted() {
        // Mirror what the Go coordinator emits when E2E is enabled.
        let raw = r#"{"type":"embedding_request","request_id":"emb-1","encrypted_body":{"ephemeral_public_key":"a2V5","ciphertext":"Y2lwaGVy"}}"#;
        let msg: CoordinatorMessage = serde_json::from_str(raw).unwrap();
        match msg {
            CoordinatorMessage::EmbeddingRequest {
                request_id,
                encrypted_body,
                ..
            } => {
                assert_eq!(request_id, "emb-1");
                let enc = encrypted_body.unwrap();
                assert_eq!(enc.ephemeral_public_key, "a2V5");
                assert_eq!(enc.ciphertext, "Y2lwaGVy");
            }
            _ => panic!("expected EmbeddingRequest"),
        }
    }

    #[test]
    fn test_embedding_request_body_array_input() {
        let body_json = r#"{"model":"bge-m3","input":["hello","world"],"encoding_format":"float","dimensions":768}"#;
        let body: EmbeddingRequestBody = serde_json::from_str(body_json).unwrap();
        assert_eq!(body.model, "bge-m3");
        let arr: Vec<String> = serde_json::from_value(body.input.clone()).unwrap();
        assert_eq!(arr, vec!["hello", "world"]);
        assert_eq!(body.encoding_format.as_deref(), Some("float"));
        assert_eq!(body.dimensions, Some(768));
    }

    #[test]
    fn test_embedding_complete_roundtrip() {
        let msg = ProviderMessage::EmbeddingComplete {
            request_id: "emb-1".to_string(),
            model: "bge-m3".to_string(),
            data: vec![EmbeddingVector {
                index: 0,
                embedding: vec![0.1, 0.2, 0.3],
            }],
            usage: EmbeddingUsage {
                prompt_tokens: 10,
                total_tokens: 10,
            },
            duration_secs: 0.05,
            encrypted_data: None,
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"embedding_complete\""));
        let decoded: ProviderMessage = serde_json::from_str(&json).unwrap();
        match decoded {
            ProviderMessage::EmbeddingComplete {
                model, data, usage, ..
            } => {
                assert_eq!(model, "bge-m3");
                assert_eq!(data.len(), 1);
                assert_eq!(usage.prompt_tokens, 10);
            }
            _ => panic!("variant mismatch"),
        }
    }

    #[test]
    fn test_embedding_complete_omits_data_when_encrypted() {
        let msg = ProviderMessage::EmbeddingComplete {
            request_id: "emb-2".to_string(),
            model: "bge-m3".to_string(),
            data: vec![],
            usage: EmbeddingUsage {
                prompt_tokens: 5,
                total_tokens: 5,
            },
            duration_secs: 0.01,
            encrypted_data: Some(EncryptedPayload {
                ephemeral_public_key: "abc".to_string(),
                ciphertext: "def".to_string(),
            }),
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(
            !json.contains("\"data\""),
            "data should be omitted when empty: {json}"
        );
        assert!(json.contains("encrypted_data"));
    }

    #[test]
    fn test_rerank_request_roundtrip() {
        let body = serde_json::json!({
            "model": "bge-rrk",
            "query": "what is X",
            "documents": ["a", "b"],
            "top_n": 1
        });
        let msg = CoordinatorMessage::RerankRequest {
            request_id: "rr-1".to_string(),
            body,
            encrypted_body: None,
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"rerank_request\""));
        let decoded: CoordinatorMessage = serde_json::from_str(&json).unwrap();
        match decoded {
            CoordinatorMessage::RerankRequest { body, .. } => {
                assert_eq!(body["query"], "what is X");
                assert_eq!(body["top_n"], 1);
            }
            _ => panic!("variant mismatch"),
        }
    }

    #[test]
    fn test_rerank_complete_roundtrip() {
        let msg = ProviderMessage::RerankComplete {
            request_id: "rr-1".to_string(),
            model: "bge-reranker".to_string(),
            results: vec![
                RerankResult {
                    index: 1,
                    relevance_score: 0.97,
                    document: None,
                },
                RerankResult {
                    index: 0,
                    relevance_score: 0.42,
                    document: Some("doc text".to_string()),
                },
            ],
            usage: RerankUsage {
                prompt_tokens: 50,
                total_tokens: 50,
            },
            duration_secs: 0.02,
            encrypted_data: None,
        };
        let json = serde_json::to_string(&msg).unwrap();
        let decoded: ProviderMessage = serde_json::from_str(&json).unwrap();
        match decoded {
            ProviderMessage::RerankComplete { results, .. } => {
                assert_eq!(results.len(), 2);
                assert_eq!(results[0].relevance_score, 0.97);
                assert_eq!(results[1].document.as_deref(), Some("doc text"));
            }
            _ => panic!("variant mismatch"),
        }
    }

    #[test]
    fn test_runtime_status_backward_compatible_deserialization() {
        // A coordinator that doesn't send mismatches field should still parse
        let raw = r#"{"type":"runtime_status","verified":true}"#;
        let msg: CoordinatorMessage = serde_json::from_str(raw).unwrap();
        match msg {
            CoordinatorMessage::RuntimeStatus {
                verified,
                mismatches,
            } => {
                assert!(verified);
                assert!(mismatches.is_empty());
            }
            _ => panic!("expected RuntimeStatus"),
        }
    }

    #[test]
    fn test_register_with_runtime_hashes_roundtrip() {
        let mut template_hashes = std::collections::HashMap::new();
        template_hashes.insert("chatml".to_string(), "abc123".to_string());
        template_hashes.insert("llama".to_string(), "def456".to_string());

        let msg = ProviderMessage::Register {
            hardware: sample_hardware(),
            models: vec![],
            backend: "vllm_mlx".to_string(),
            version: None,
            public_key: None,
            wallet_address: None,
            attestation: None,
            prefill_tps: None,
            decode_tps: None,
            auth_token: None,
            python_hash: Some("pythonhash123".to_string()),
            runtime_hash: Some("runtimehash456".to_string()),
            template_hashes,
            grpc_binary_hash: None,
            image_bridge_hash: None,
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"python_hash\":\"pythonhash123\""));
        assert!(json.contains("\"runtime_hash\":\"runtimehash456\""));
        assert!(json.contains("\"template_hashes\""));
        assert!(json.contains("\"chatml\""));
        let deserialized: ProviderMessage = serde_json::from_str(&json).unwrap();
        // Compare fields individually (HashMap order is non-deterministic)
        match deserialized {
            ProviderMessage::Register {
                python_hash,
                runtime_hash,
                template_hashes,
                ..
            } => {
                assert_eq!(python_hash, Some("pythonhash123".to_string()));
                assert_eq!(runtime_hash, Some("runtimehash456".to_string()));
                assert_eq!(template_hashes.get("chatml"), Some(&"abc123".to_string()));
                assert_eq!(template_hashes.get("llama"), Some(&"def456".to_string()));
                assert_eq!(template_hashes.len(), 2);
            }
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn test_register_backward_compatible_without_runtime_hashes() {
        // An old-format Register message without runtime hash fields should still parse
        let raw = r#"{"type":"register","hardware":{"machine_model":"Mac16,1","chip_name":"Apple M4 Max","chip_family":"M4","chip_tier":"Max","memory_gb":128,"memory_available_gb":124,"cpu_cores":{"total":16,"performance":12,"efficiency":4},"gpu_cores":40,"memory_bandwidth_gbs":546},"models":[],"backend":"vllm_mlx"}"#;
        let msg: ProviderMessage = serde_json::from_str(raw).unwrap();
        match msg {
            ProviderMessage::Register {
                python_hash,
                runtime_hash,
                template_hashes,
                ..
            } => {
                assert!(python_hash.is_none());
                assert!(runtime_hash.is_none());
                assert!(template_hashes.is_empty());
            }
            _ => panic!("expected Register"),
        }
    }
}
