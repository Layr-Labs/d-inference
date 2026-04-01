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
        /// Device-linked provider token (from `dginf-provider login`).
        /// When present, the coordinator links this provider to the token's account.
        #[serde(skip_serializing_if = "Option::is_none")]
        auth_token: Option<String>,
    },
    Heartbeat {
        status: ProviderStatus,
        #[serde(skip_serializing_if = "Option::is_none")]
        active_model: Option<String>,
        stats: ProviderStats,
        system_metrics: SystemMetrics,
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
    /// Image generation result — base64-encoded images.
    ImageGenerationComplete {
        request_id: String,
        images: Vec<ImageDataPayload>,
        usage: ImageGenerationUsage,
        /// Processing time in seconds.
        duration_secs: f64,
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
    ImageGenerationRequest {
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

/// PartialEq via serialized JSON — needed because Box<RawValue> (in Register's
/// attestation field) doesn't implement PartialEq directly.
impl PartialEq for ProviderMessage {
    fn eq(&self, other: &Self) -> bool {
        let a = serde_json::to_string(self).unwrap_or_default();
        let b = serde_json::to_string(other).unwrap_or_default();
        a == b
    }
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
            }],
            backend: "vllm_mlx".to_string(),
            public_key: None,
            wallet_address: None,
            attestation: None,
            prefill_tps: None,
            decode_tps: None,
            auth_token: None,
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
            }],
            backend: "vllm_mlx".to_string(),
            public_key: None,
            wallet_address: Some("0x1234567890abcdef1234567890abcdef12345678".to_string()),
            attestation: None,
            prefill_tps: None,
            decode_tps: None,
            auth_token: None,
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
            }],
            backend: "vllm_mlx".to_string(),
            public_key: Some("c29tZWtleQ==".to_string()),
            wallet_address: None,
            attestation: Some(attestation_raw),
            prefill_tps: Some(500.0),
            decode_tps: Some(100.0),
            auth_token: None,
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
            stats: ProviderStats::default(),
            system_metrics: SystemMetrics {
                memory_pressure: 0.0,
                cpu_usage: 0.0,
                thermal_state: ThermalState::Nominal,
            },
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
            stats: ProviderStats {
                requests_served: 10,
                tokens_generated: 5000,
            },
            system_metrics: SystemMetrics {
                memory_pressure: 0.3,
                cpu_usage: 0.5,
                thermal_state: ThermalState::Nominal,
            },
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
            CoordinatorMessage::InferenceRequest { request_id, body, .. } => {
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
            stats: ProviderStats::default(),
            system_metrics: SystemMetrics {
                memory_pressure: 0.65,
                cpu_usage: 0.3,
                thermal_state: ThermalState::Nominal,
            },
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"system_metrics\""));
        assert!(json.contains("\"memory_pressure\":0.65"));
        assert!(json.contains("\"thermal_state\":\"nominal\""));
        let deserialized: ProviderMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, deserialized);
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
            CoordinatorMessage::TranscriptionRequest { request_id, body, encrypted_body } => {
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
            CoordinatorMessage::TranscriptionRequest { request_id, encrypted_body, .. } => {
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
            body,
            encrypted_body: None,
        };

        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"image_generation_request\""));
        assert!(json.contains("\"request_id\":\"img-123\""));
        assert!(json.contains("\"prompt\":\"a cat wearing a hat\""));
        let deserialized: CoordinatorMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, deserialized);
    }

    #[test]
    fn test_image_generation_complete_roundtrip() {
        let msg = ProviderMessage::ImageGenerationComplete {
            request_id: "img-456".to_string(),
            images: vec![ImageDataPayload {
                b64_json: "iVBORw0KGgo=".to_string(),
            }],
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
        assert!(json.contains("\"b64_json\":\"iVBORw0KGgo=\""));
        let deserialized: ProviderMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, deserialized);
    }

    #[test]
    fn test_deserialize_image_generation_request_from_go_json() {
        let raw = r#"{"type":"image_generation_request","request_id":"go-img-1","body":{"model":"flux-klein-4b","prompt":"sunset over mountains","n":2,"size":"512x512"}}"#;
        let msg: CoordinatorMessage = serde_json::from_str(raw).unwrap();
        match msg {
            CoordinatorMessage::ImageGenerationRequest { request_id, body, encrypted_body } => {
                assert_eq!(request_id, "go-img-1");
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
        let raw = r#"{"type":"image_generation_request","request_id":"enc-img-1","encrypted_body":{"ephemeral_public_key":"a2V5","ciphertext":"Y2lwaGVy"}}"#;
        let msg: CoordinatorMessage = serde_json::from_str(raw).unwrap();
        match msg {
            CoordinatorMessage::ImageGenerationRequest { request_id, encrypted_body, .. } => {
                assert_eq!(request_id, "enc-img-1");
                let enc = encrypted_body.unwrap();
                assert_eq!(enc.ephemeral_public_key, "a2V5");
                assert_eq!(enc.ciphertext, "Y2lwaGVy");
            }
            _ => panic!("expected ImageGenerationRequest"),
        }
    }
}
