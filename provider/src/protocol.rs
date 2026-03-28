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
    /// Response to an attestation challenge from the coordinator.
    /// Includes a fresh SIP status check — the coordinator verifies this
    /// hasn't changed since registration.
    AttestationResponse {
        nonce: String,
        signature: String,
        public_key: String,
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
    Cancel {
        request_id: String,
    },
    /// Attestation challenge — provider must sign nonce+timestamp and respond.
    AttestationChallenge {
        nonce: String,
        timestamp: String,
    },
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
}
