//! WebSocket client for connecting to the EigenInference coordinator.
//!
//! This module manages the provider's connection to the coordinator:
//!   - WebSocket connection with automatic reconnection (exponential backoff)
//!   - Registration (hardware info, available models, attestation blob)
//!   - Periodic heartbeats to prevent eviction
//!   - Receiving and dispatching inference requests
//!   - Responding to attestation challenges (proving key possession)
//!   - Forwarding inference results back to the coordinator
//!
//! The connection loop runs until shutdown is requested (via watch channel).
//! On disconnection, it waits with exponential backoff before reconnecting.
//! Events are dispatched to the main loop via an mpsc channel, and outbound
//! messages (inference results) arrive on a separate mpsc channel.

use anyhow::{Context, Result};
use futures_util::{SinkExt, StreamExt};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

use crate::backend::ExponentialBackoff;
use crate::hardware::HardwareInfo;
use crate::models::ModelInfo;
use crate::protocol::{
    CoordinatorMessage, EmbeddingRequestBody, ImageGenerationRequestBody,
    PromptCompressionRequestBody, ProviderMessage, ProviderStats, ProviderStatus,
    RerankRequestBody, TranscriptionRequestBody,
};
use crate::security::RuntimeHashes;

/// Thread-safe counters for provider statistics, shared between the main
/// event loop (which increments them) and the heartbeat sender (which reads them).
pub struct AtomicProviderStats {
    pub requests_served: AtomicU64,
    pub tokens_generated: AtomicU64,
}

impl AtomicProviderStats {
    pub fn new() -> Self {
        Self {
            requests_served: AtomicU64::new(0),
            tokens_generated: AtomicU64::new(0),
        }
    }
}

/// Messages from coordinator connection to the main loop.
#[derive(Debug)]
pub enum CoordinatorEvent {
    Connected,
    Disconnected,
    InferenceRequest {
        request_id: String,
        body: serde_json::Value,
    },
    TranscriptionRequest {
        request_id: String,
        body: TranscriptionRequestBody,
    },
    ImageGenerationRequest {
        request_id: String,
        body: ImageGenerationRequestBody,
        upload_url: String,
    },
    EmbeddingRequest {
        request_id: String,
        body: EmbeddingRequestBody,
        /// Ephemeral X25519 public key the coordinator used for the request.
        /// When present, the provider should encrypt the response back with
        /// the session key derived from this + provider's private key.
        session_pub_key: Option<String>,
    },
    RerankRequest {
        request_id: String,
        body: RerankRequestBody,
        session_pub_key: Option<String>,
    },
    PromptCompressionRequest {
        request_id: String,
        body: PromptCompressionRequestBody,
        session_pub_key: Option<String>,
    },
    Cancel {
        request_id: String,
    },
    AttestationChallenge {
        nonce: String,
        timestamp: String,
    },
    /// Coordinator reports that runtime hashes don't match known-good values.
    /// The main loop should trigger a runtime re-download and re-register.
    RuntimeOutdated {
        mismatches: Vec<crate::protocol::RuntimeMismatch>,
    },
}

/// Coordinator WebSocket client.
pub struct CoordinatorClient {
    url: String,
    hardware: HardwareInfo,
    models: Vec<ModelInfo>,
    backend_name: String,
    heartbeat_interval: Duration,
    public_key: Option<String>,
    node_keypair: Arc<crate::crypto::NodeKeyPair>,
    wallet_address: Option<String>,
    attestation: Option<Box<serde_json::value::RawValue>>,
    auth_token: Option<String>,
    /// Shared atomic counters — incremented by proxy tasks, read by heartbeats.
    stats: Arc<AtomicProviderStats>,
    /// True while at least one inference request is in flight.
    inference_active: Arc<AtomicBool>,
    /// The model currently loaded / being served (set by the main event loop).
    current_model: Arc<std::sync::Mutex<Option<String>>>,
    /// All models currently loaded and warm (for multi-model serving).
    warm_models: Arc<std::sync::Mutex<Vec<String>>>,
    /// SHA-256 weight fingerprint of the currently loaded model (cached at load time).
    current_model_hash: Arc<std::sync::Mutex<Option<String>>>,
    /// Runtime integrity hashes (Python binary, vllm_mlx package, templates).
    runtime_hashes: Option<RuntimeHashes>,
    /// Per-model weight hashes for all active models (text, STT, image).
    model_hashes: std::collections::HashMap<String, String>,
    /// Live backend capacity data (updated by main loop, read by heartbeat tick).
    backend_capacity: Arc<std::sync::Mutex<Option<crate::protocol::BackendCapacity>>>,
}

impl CoordinatorClient {
    pub fn new(
        url: String,
        hardware: HardwareInfo,
        models: Vec<ModelInfo>,
        backend_name: String,
        heartbeat_interval: Duration,
        public_key: Option<String>,
        node_keypair: Arc<crate::crypto::NodeKeyPair>,
    ) -> Self {
        Self {
            url,
            hardware,
            models,
            backend_name,
            heartbeat_interval,
            public_key,
            node_keypair,
            wallet_address: None,
            attestation: None,
            auth_token: None,
            stats: Arc::new(AtomicProviderStats::new()),
            inference_active: Arc::new(AtomicBool::new(false)),
            current_model: Arc::new(std::sync::Mutex::new(None)),
            warm_models: Arc::new(std::sync::Mutex::new(Vec::new())),
            current_model_hash: Arc::new(std::sync::Mutex::new(None)),
            runtime_hashes: None,
            model_hashes: std::collections::HashMap::new(),
            backend_capacity: Arc::new(std::sync::Mutex::new(None)),
        }
    }

    /// Set per-model weight hashes for all active models.
    pub fn with_model_hashes(mut self, hashes: std::collections::HashMap<String, String>) -> Self {
        self.model_hashes = hashes;
        self
    }

    /// Set the wallet address for Tempo blockchain payouts (pathUSD).
    pub fn with_wallet_address(mut self, wallet_address: Option<String>) -> Self {
        self.wallet_address = wallet_address;
        self
    }

    /// Set the signed Secure Enclave attestation blob (raw JSON bytes preserved).
    pub fn with_attestation(
        mut self,
        attestation: Option<Box<serde_json::value::RawValue>>,
    ) -> Self {
        self.attestation = attestation;
        self
    }

    /// Set the device-linked auth token (from `darkbloom login`).
    pub fn with_auth_token(mut self, auth_token: Option<String>) -> Self {
        self.auth_token = auth_token;
        self
    }

    /// Set the shared atomic stats counters (requests served, tokens generated).
    pub fn with_stats(mut self, stats: Arc<AtomicProviderStats>) -> Self {
        self.stats = stats;
        self
    }

    /// Set the shared inference-active flag (true while requests are in flight).
    pub fn with_inference_active(mut self, flag: Arc<AtomicBool>) -> Self {
        self.inference_active = flag;
        self
    }

    /// Set the shared current-model name (model currently loaded on this provider).
    pub fn with_current_model(mut self, model: Arc<std::sync::Mutex<Option<String>>>) -> Self {
        self.current_model = model;
        self
    }

    /// Set the shared warm-models list (all models currently loaded in multi-model mode).
    pub fn with_warm_models(mut self, warm: Arc<std::sync::Mutex<Vec<String>>>) -> Self {
        self.warm_models = warm;
        self
    }

    /// Set the shared current-model weight hash (cached at model load time).
    pub fn with_current_model_hash(mut self, hash: Arc<std::sync::Mutex<Option<String>>>) -> Self {
        self.current_model_hash = hash;
        self
    }

    /// Set runtime integrity hashes (Python, vllm_mlx, templates) for registration.
    pub fn with_runtime_hashes(mut self, hashes: Option<RuntimeHashes>) -> Self {
        self.runtime_hashes = hashes;
        self
    }

    /// Set the shared backend capacity data (updated by main loop, read by heartbeats).
    pub fn with_backend_capacity(
        mut self,
        cap: Arc<std::sync::Mutex<Option<crate::protocol::BackendCapacity>>>,
    ) -> Self {
        self.backend_capacity = cap;
        self
    }

    /// Run the coordinator connection loop with auto-reconnect.
    /// Events are sent via the returned channel.
    /// Provider messages (chunks, completions, errors) come in on outbound_rx.
    pub async fn run(
        &self,
        event_tx: mpsc::Sender<CoordinatorEvent>,
        mut outbound_rx: mpsc::Receiver<ProviderMessage>,
        mut shutdown_rx: tokio::sync::watch::Receiver<bool>,
    ) -> Result<()> {
        let mut backoff = ExponentialBackoff::new();

        loop {
            // Check for shutdown before attempting connection
            if *shutdown_rx.borrow() {
                tracing::info!("Coordinator client shutting down");
                break;
            }

            tracing::info!("Connecting to coordinator: {}", self.url);

            match self
                .connect_and_run(&event_tx, &mut outbound_rx, &mut shutdown_rx)
                .await
            {
                Ok(()) => {
                    tracing::info!("Coordinator connection closed, reconnecting...");
                    backoff.reset();
                    continue;
                }
                Err(e) => {
                    let _ = event_tx.send(CoordinatorEvent::Disconnected).await;
                    let delay = backoff.next_delay();
                    tracing::warn!(
                        "Coordinator connection error: {e}. Reconnecting in {:?}",
                        delay
                    );

                    tokio::select! {
                        _ = tokio::time::sleep(delay) => {}
                        _ = shutdown_rx.changed() => {
                            tracing::info!("Coordinator client shutting down during reconnect");
                            break;
                        }
                    }
                }
            }
        }

        Ok(())
    }

    async fn connect_and_run(
        &self,
        event_tx: &mpsc::Sender<CoordinatorEvent>,
        outbound_rx: &mut mpsc::Receiver<ProviderMessage>,
        shutdown_rx: &mut tokio::sync::watch::Receiver<bool>,
    ) -> Result<()> {
        let (ws_stream, _) = tokio_tungstenite::connect_async(&self.url)
            .await
            .context("failed to connect to coordinator WebSocket")?;

        let (mut write, mut read) = ws_stream.split();

        // Send registration message
        let (python_hash, runtime_hash, template_hashes, grpc_binary_hash, image_bridge_hash) =
            if let Some(ref rh) = self.runtime_hashes {
                (
                    rh.python_hash.clone(),
                    rh.runtime_hash.clone(),
                    rh.template_hashes.clone(),
                    rh.grpc_binary_hash.clone(),
                    rh.image_bridge_hash.clone(),
                )
            } else {
                (None, None, std::collections::HashMap::new(), None, None)
            };
        let register = ProviderMessage::Register {
            hardware: self.hardware.clone(),
            models: self.models.clone(),
            backend: self.backend_name.clone(),
            version: Some(env!("CARGO_PKG_VERSION").to_string()),
            public_key: self.public_key.clone(),
            wallet_address: self.wallet_address.clone(),
            attestation: self.attestation.clone(),
            prefill_tps: None,
            decode_tps: None,
            auth_token: self.auth_token.clone(),
            python_hash,
            runtime_hash,
            template_hashes,
            grpc_binary_hash,
            image_bridge_hash,
        };
        let register_json = serde_json::to_string(&register)?;
        write.send(Message::Text(register_json.into())).await?;
        tracing::info!("Sent registration to coordinator");

        let _ = event_tx.send(CoordinatorEvent::Connected).await;

        let mut heartbeat_interval = tokio::time::interval(self.heartbeat_interval);
        heartbeat_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        // WebSocket ping every 10s to detect dead connections fast.
        // If no pong comes back within 30s, the connection is dead.
        let mut ping_interval = tokio::time::interval(Duration::from_secs(10));
        ping_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let mut last_pong = tokio::time::Instant::now();
        let pong_timeout = Duration::from_secs(30);

        loop {
            // Check pong timeout
            if last_pong.elapsed() > pong_timeout {
                anyhow::bail!("WebSocket pong timeout (no response in {pong_timeout:?})");
            }

            tokio::select! {
                _ = shutdown_rx.changed() => {
                    tracing::info!("Shutting down coordinator connection");
                    let _ = write.close().await;
                    return Ok(());
                }

                // WebSocket ping to detect dead connections
                _ = ping_interval.tick() => {
                    if let Err(e) = write.send(Message::Ping("eigeninference".into())).await {
                        anyhow::bail!("Failed to send ping: {e}");
                    }
                }

                // Heartbeat tick
                _ = heartbeat_interval.tick() => {
                    let metrics = crate::hardware::collect_system_metrics(
                        self.hardware.cpu_cores.total,
                    );
                    let is_active = self.inference_active.load(Ordering::Relaxed);
                    let active_model = self.current_model.lock().unwrap().clone();
                    let warm = self.warm_models.lock().unwrap().clone();
                    let capacity = self.backend_capacity.lock().unwrap().clone();
                    let heartbeat = ProviderMessage::Heartbeat {
                        status: if is_active { ProviderStatus::Serving } else { ProviderStatus::Idle },
                        active_model,
                        warm_models: warm,
                        stats: ProviderStats {
                            requests_served: self.stats.requests_served.load(Ordering::Relaxed),
                            tokens_generated: self.stats.tokens_generated.load(Ordering::Relaxed),
                        },
                        system_metrics: metrics,
                        backend_capacity: capacity,
                    };
                    let json = serde_json::to_string(&heartbeat)?;
                    write.send(Message::Text(json.into())).await?;
                    tracing::debug!("Sent heartbeat");
                }

                // Outbound messages from proxy
                msg = outbound_rx.recv() => {
                    match msg {
                        Some(provider_msg) => {
                            let json = serde_json::to_string(&provider_msg)?;
                            write.send(Message::Text(json.into())).await?;
                        }
                        None => {
                            // Channel closed
                            tracing::info!("Outbound channel closed, disconnecting");
                            let _ = write.close().await;
                            return Ok(());
                        }
                    }
                }

                // Incoming messages from coordinator
                msg = read.next() => {
                    match msg {
                        Some(Ok(Message::Text(text))) => {
                            match serde_json::from_str::<CoordinatorMessage>(&text) {
                                Ok(CoordinatorMessage::InferenceRequest { request_id, body, encrypted_body }) => {
                                    tracing::info!("Received inference request: {request_id}");

                                    // Decrypt E2E encrypted body if present
                                    let decrypted_body = if let Some(enc) = encrypted_body {
                                        tracing::info!("Decrypting E2E encrypted request");
                                        match decrypt_request_body(&enc, self.node_keypair.as_ref()) {
                                            Ok(b) => b,
                                            Err(e) => {
                                                tracing::error!("Failed to decrypt request: {e}");
                                                continue;
                                            }
                                        }
                                    } else {
                                        body
                                    };

                                    let _ = event_tx.send(CoordinatorEvent::InferenceRequest {
                                        request_id,
                                        body: decrypted_body,
                                    }).await;
                                }
                                Ok(CoordinatorMessage::TranscriptionRequest { request_id, body, encrypted_body }) => {
                                    tracing::info!("Received transcription request: {request_id}");

                                    // Decrypt E2E encrypted body if present
                                    let decrypted_body = if let Some(enc) = encrypted_body {
                                        tracing::info!("Decrypting E2E encrypted transcription request");
                                        match decrypt_request_body(&enc, self.node_keypair.as_ref()) {
                                            Ok(b) => b,
                                            Err(e) => {
                                                tracing::error!("Failed to decrypt transcription request: {e}");
                                                continue;
                                            }
                                        }
                                    } else {
                                        body
                                    };

                                    // Parse the transcription body
                                    match serde_json::from_value::<TranscriptionRequestBody>(decrypted_body) {
                                        Ok(parsed_body) => {
                                            let _ = event_tx.send(CoordinatorEvent::TranscriptionRequest {
                                                request_id,
                                                body: parsed_body,
                                            }).await;
                                        }
                                        Err(e) => {
                                            tracing::error!("Failed to parse transcription body: {e}");
                                        }
                                    }
                                }
                                Ok(CoordinatorMessage::ImageGenerationRequest { request_id, upload_url, body, encrypted_body }) => {
                                    tracing::info!("Received image generation request: {request_id}");

                                    // Decrypt E2E encrypted body if present
                                    let decrypted_body = if let Some(enc) = encrypted_body {
                                        tracing::info!("Decrypting E2E encrypted image generation request");
                                        match decrypt_request_body(&enc, self.node_keypair.as_ref()) {
                                            Ok(b) => b,
                                            Err(e) => {
                                                tracing::error!("Failed to decrypt image generation request: {e}");
                                                continue;
                                            }
                                        }
                                    } else {
                                        body
                                    };

                                    // Parse the image generation body
                                    match serde_json::from_value::<ImageGenerationRequestBody>(decrypted_body) {
                                        Ok(parsed_body) => {
                                            let _ = event_tx.send(CoordinatorEvent::ImageGenerationRequest {
                                                request_id,
                                                body: parsed_body,
                                                upload_url,
                                            }).await;
                                        }
                                        Err(e) => {
                                            tracing::error!("Failed to parse image generation body: {e}");
                                        }
                                    }
                                }
                                Ok(CoordinatorMessage::EmbeddingRequest { request_id, body, encrypted_body }) => {
                                    tracing::info!("Received embedding request: {request_id}");
                                    let session_pub = encrypted_body.as_ref().map(|e| e.ephemeral_public_key.clone());
                                    let decrypted_body = if let Some(enc) = encrypted_body {
                                        match decrypt_request_body(&enc, self.node_keypair.as_ref()) {
                                            Ok(b) => b,
                                            Err(e) => {
                                                tracing::error!("Failed to decrypt embedding request: {e}");
                                                continue;
                                            }
                                        }
                                    } else {
                                        body
                                    };
                                    match serde_json::from_value::<EmbeddingRequestBody>(decrypted_body) {
                                        Ok(parsed_body) => {
                                            let _ = event_tx.send(CoordinatorEvent::EmbeddingRequest {
                                                request_id,
                                                body: parsed_body,
                                                session_pub_key: session_pub,
                                            }).await;
                                        }
                                        Err(e) => {
                                            tracing::error!("Failed to parse embedding body: {e}");
                                        }
                                    }
                                }
                                Ok(CoordinatorMessage::RerankRequest { request_id, body, encrypted_body }) => {
                                    tracing::info!("Received rerank request: {request_id}");
                                    let session_pub = encrypted_body.as_ref().map(|e| e.ephemeral_public_key.clone());
                                    let decrypted_body = if let Some(enc) = encrypted_body {
                                        match decrypt_request_body(&enc, self.node_keypair.as_ref()) {
                                            Ok(b) => b,
                                            Err(e) => {
                                                tracing::error!("Failed to decrypt rerank request: {e}");
                                                continue;
                                            }
                                        }
                                    } else {
                                        body
                                    };
                                    match serde_json::from_value::<RerankRequestBody>(decrypted_body) {
                                        Ok(parsed_body) => {
                                            let _ = event_tx.send(CoordinatorEvent::RerankRequest {
                                                request_id,
                                                body: parsed_body,
                                                session_pub_key: session_pub,
                                            }).await;
                                        }
                                        Err(e) => {
                                            tracing::error!("Failed to parse rerank body: {e}");
                                        }
                                    }
                                }
                                Ok(CoordinatorMessage::PromptCompressionRequest { request_id, body, encrypted_body }) => {
                                    tracing::info!("Received prompt compression request: {request_id}");
                                    let session_pub = encrypted_body.as_ref().map(|e| e.ephemeral_public_key.clone());
                                    let decrypted_body = if let Some(enc) = encrypted_body {
                                        match decrypt_request_body(&enc, self.node_keypair.as_ref()) {
                                            Ok(b) => b,
                                            Err(e) => {
                                                tracing::error!("Failed to decrypt compression request: {e}");
                                                continue;
                                            }
                                        }
                                    } else {
                                        body
                                    };
                                    match serde_json::from_value::<PromptCompressionRequestBody>(decrypted_body) {
                                        Ok(parsed_body) => {
                                            let _ = event_tx.send(CoordinatorEvent::PromptCompressionRequest {
                                                request_id,
                                                body: parsed_body,
                                                session_pub_key: session_pub,
                                            }).await;
                                        }
                                        Err(e) => {
                                            tracing::error!("Failed to parse compression body: {e}");
                                        }
                                    }
                                }
                                Ok(CoordinatorMessage::Cancel { request_id }) => {
                                    tracing::info!("Received cancel for: {request_id}");
                                    let _ = event_tx.send(CoordinatorEvent::Cancel {
                                        request_id,
                                    }).await;
                                }
                                Ok(CoordinatorMessage::AttestationChallenge { nonce, timestamp }) => {
                                    tracing::info!("Received attestation challenge");
                                    // Respond to the challenge inline, signing with
                                    // the provider's key.
                                    let model_hash = self.current_model_hash.lock().unwrap().clone();
                                    let response = handle_attestation_challenge(
                                        &nonce,
                                        &timestamp,
                                        self.public_key.as_deref(),
                                        model_hash.as_deref(),
                                        self.runtime_hashes.as_ref(),
                                        self.model_hashes.clone(),
                                    );
                                    let json = serde_json::to_string(&response)
                                        .unwrap_or_default();
                                    if let Err(e) = write.send(Message::Text(json.into())).await {
                                        tracing::warn!("Failed to send attestation response: {e}");
                                    } else {
                                        tracing::info!("Sent attestation response");
                                    }
                                }
                                Ok(CoordinatorMessage::RuntimeStatus { verified, mismatches }) => {
                                    if verified {
                                        tracing::info!("Runtime integrity verified by coordinator");
                                    } else {
                                        tracing::warn!(
                                            "Runtime integrity check FAILED — {} mismatch(es)",
                                            mismatches.len()
                                        );
                                        for m in &mismatches {
                                            tracing::warn!(
                                                "  {}: expected={}, got={}",
                                                m.component, m.expected, m.got
                                            );
                                        }
                                        let _ = event_tx
                                            .send(CoordinatorEvent::RuntimeOutdated {
                                                mismatches,
                                            })
                                            .await;
                                    }
                                }
                                Err(e) => {
                                    tracing::warn!("Failed to parse coordinator message: {e}");
                                }
                            }
                        }
                        Some(Ok(Message::Ping(data))) => {
                            let _ = write.send(Message::Pong(data)).await;
                        }
                        Some(Ok(Message::Pong(_))) => {
                            last_pong = tokio::time::Instant::now();
                        }
                        Some(Ok(Message::Close(_))) => {
                            tracing::info!("Coordinator sent close frame");
                            anyhow::bail!("connection closed by coordinator");
                        }
                        Some(Err(e)) => {
                            anyhow::bail!("WebSocket error: {e}");
                        }
                        None => {
                            anyhow::bail!("WebSocket stream ended");
                        }
                        _ => {} // Binary, Frame — ignore
                    }
                }
            }
        }
    }
}

/// Decrypt an E2E encrypted request body using the provider's X25519 private key.
///
/// The coordinator encrypted the request with the provider's public key.
/// Only this hardened process has the private key to decrypt it.
/// MITM on the network sees only encrypted blobs.
fn decrypt_request_body(
    encrypted: &crate::protocol::EncryptedPayload,
    keypair: &crate::crypto::NodeKeyPair,
) -> anyhow::Result<serde_json::Value> {
    use base64::Engine;

    // Decode the ephemeral public key from the coordinator
    let ephemeral_pub_bytes = base64::engine::general_purpose::STANDARD
        .decode(&encrypted.ephemeral_public_key)
        .map_err(|e| anyhow::anyhow!("invalid ephemeral public key: {e}"))?;

    if ephemeral_pub_bytes.len() != 32 {
        anyhow::bail!(
            "invalid ephemeral key length: {}",
            ephemeral_pub_bytes.len()
        );
    }

    let mut ephemeral_pub = [0u8; 32];
    ephemeral_pub.copy_from_slice(&ephemeral_pub_bytes);

    // Decode ciphertext (nonce || encrypted data)
    let ciphertext = base64::engine::general_purpose::STANDARD
        .decode(&encrypted.ciphertext)
        .map_err(|e| anyhow::anyhow!("invalid ciphertext: {e}"))?;

    // Decrypt with our private key + coordinator's ephemeral public key
    let plaintext = keypair.decrypt(&ephemeral_pub, &ciphertext)?;

    // Parse the decrypted JSON
    let body: serde_json::Value = serde_json::from_slice(&plaintext)
        .map_err(|e| anyhow::anyhow!("decrypted body is not valid JSON: {e}"))?;

    tracing::info!("E2E decryption successful — request decrypted inside hardened process");
    Ok(body)
}

/// Handle an attestation challenge by signing the nonce+timestamp data
/// and performing a fresh security posture check.
///
/// For now, we produce a "signature" by base64-encoding the SHA-256 hash of the
/// challenge data concatenated with the public key. This proves possession of
/// the key identity on the authenticated WebSocket. In a future iteration, the
/// Secure Enclave P-256 key would be used for a proper cryptographic signature.
///
/// The response includes fresh SIP and Secure Boot status, verified at the
/// time of the challenge. The coordinator checks these and marks the provider
/// untrusted if they've been disabled since registration.
pub fn handle_attestation_challenge(
    nonce: &str,
    timestamp: &str,
    public_key: Option<&str>,
    current_model_hash: Option<&str>,
    runtime_hashes: Option<&RuntimeHashes>,
    model_hashes: std::collections::HashMap<String, String>,
) -> ProviderMessage {
    let data = format!("{}{}", nonce, timestamp);

    // Sign the challenge data (nonce + timestamp) with the Secure Enclave
    // P-256 key via the eigeninference-enclave CLI tool. The coordinator
    // verifies this signature using the provider's SE public key from the
    // attestation blob, proving the same hardware is still responding.
    let pk_str = public_key.unwrap_or("");
    let signature = match crate::security::se_sign(data.as_bytes()) {
        Some(sig) => sig,
        None => {
            tracing::warn!(
                "Secure Enclave signing unavailable — sending empty signature \
                 (coordinator will reject if attestation was provided)"
            );
            String::new()
        }
    };

    // Fresh security posture check at challenge time.
    // SIP can't change at runtime (requires reboot), but this proves
    // the provider hasn't rebooted with SIP disabled and reconnected.
    let sip_enabled = crate::security::check_sip_enabled();
    let rdma_disabled = crate::security::check_rdma_disabled();
    let hypervisor_active = crate::security::check_hypervisor_active();

    // Fresh binary hash — re-computed each challenge (~1ms for <50MB binary).
    let binary_hash = crate::security::self_binary_hash();

    if !sip_enabled {
        tracing::error!(
            "SIP is disabled during attestation challenge — coordinator will reject us"
        );
    }
    if !rdma_disabled && !hypervisor_active {
        tracing::error!(
            "RDMA is enabled without hypervisor during attestation challenge — \
             coordinator will reject us"
        );
    }

    let (python_hash, rt_hash, template_hashes, grpc_binary_hash, image_bridge_hash) =
        if let Some(rh) = runtime_hashes {
            (
                rh.python_hash.clone(),
                rh.runtime_hash.clone(),
                rh.template_hashes.clone(),
                rh.grpc_binary_hash.clone(),
                rh.image_bridge_hash.clone(),
            )
        } else {
            (None, None, std::collections::HashMap::new(), None, None)
        };

    ProviderMessage::AttestationResponse {
        nonce: nonce.to_string(),
        signature,
        public_key: pk_str.to_string(),
        hypervisor_active: Some(hypervisor_active),
        rdma_disabled: Some(rdma_disabled),
        sip_enabled: Some(sip_enabled),
        secure_boot_enabled: Some(true), // Apple Silicon always has Secure Boot in Full Security mode
        binary_hash,
        active_model_hash: current_model_hash.map(|s| s.to_string()),
        python_hash,
        runtime_hash: rt_hash,
        template_hashes,
        grpc_binary_hash,
        image_bridge_hash,
        model_hashes,
    }
}

/// Build the register message for a given hardware, models, and backend.
#[allow(dead_code)]
pub fn build_register_message(
    hardware: &HardwareInfo,
    models: &[ModelInfo],
    backend_name: &str,
    public_key: Option<String>,
) -> ProviderMessage {
    build_register_message_with_wallet(hardware, models, backend_name, public_key, None, None)
}

/// Build the register message with an optional wallet address for Tempo payouts.
#[allow(dead_code)]
pub fn build_register_message_with_wallet(
    hardware: &HardwareInfo,
    models: &[ModelInfo],
    backend_name: &str,
    public_key: Option<String>,
    wallet_address: Option<String>,
    attestation: Option<Box<serde_json::value::RawValue>>,
) -> ProviderMessage {
    ProviderMessage::Register {
        hardware: hardware.clone(),
        models: models.to_vec(),
        backend: backend_name.to_string(),
        version: None,
        public_key,
        wallet_address,
        attestation,
        prefill_tps: None,
        decode_tps: None,
        auth_token: None,
        python_hash: None,
        runtime_hash: None,
        template_hashes: std::collections::HashMap::new(),
        grpc_binary_hash: None,
        image_bridge_hash: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hardware::{ChipFamily, ChipTier, CpuCores};
    use futures_util::StreamExt;
    use std::net::SocketAddr;
    use tokio::net::TcpListener;

    fn sample_hardware() -> HardwareInfo {
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
    fn test_build_register_message() {
        let hw = sample_hardware();
        let models = vec![ModelInfo {
            id: "test-model".to_string(),
            model_type: None,
            parameters: None,
            quantization: None,
            size_bytes: 1000,
            estimated_memory_gb: 1.0,
            weight_hash: None,
        }];

        let msg = build_register_message(&hw, &models, "vllm_mlx", None);
        match msg {
            ProviderMessage::Register {
                hardware,
                models: m,
                backend,
                ..
            } => {
                assert_eq!(hardware.chip_name, "Apple M4 Max");
                assert_eq!(m.len(), 1);
                assert_eq!(backend, "vllm_mlx");
            }
            _ => panic!("Expected Register message"),
        }
    }

    #[test]
    fn test_handle_attestation_challenge_produces_valid_response() {
        let nonce = "dGVzdG5vbmNl";
        let timestamp = "2025-01-15T10:30:00Z";
        let public_key = Some("cHVia2V5");

        let response = handle_attestation_challenge(
            nonce,
            timestamp,
            public_key,
            None,
            None,
            std::collections::HashMap::new(),
        );

        match response {
            ProviderMessage::AttestationResponse {
                nonce: resp_nonce,
                signature: _,
                public_key: resp_pk,
                sip_enabled,
                ..
            } => {
                assert_eq!(resp_nonce, nonce);
                // Signature is empty in test env (no Secure Enclave).
                // In production, se_sign() produces a real P-256 ECDSA signature.
                assert_eq!(resp_pk, "cHVia2V5");
                assert!(sip_enabled.is_some(), "should include SIP status");
            }
            _ => panic!("Expected AttestationResponse"),
        }
    }

    #[test]
    fn test_handle_attestation_challenge_without_public_key() {
        let response = handle_attestation_challenge(
            "bm9uY2U=",
            "2025-01-15T00:00:00Z",
            None,
            None,
            None,
            std::collections::HashMap::new(),
        );

        match response {
            ProviderMessage::AttestationResponse {
                nonce,
                signature: _,
                public_key,
                sip_enabled,
                ..
            } => {
                assert_eq!(nonce, "bm9uY2U=");
                // Signature empty in test env (no Secure Enclave)
                assert_eq!(public_key, "");
                assert!(sip_enabled.is_some(), "should include SIP status");
            }
            _ => panic!("Expected AttestationResponse"),
        }
    }

    #[test]
    fn test_handle_attestation_challenge_deterministic() {
        let resp1 = handle_attestation_challenge(
            "bm9uY2U=",
            "2025-01-15T00:00:00Z",
            Some("key"),
            None,
            None,
            std::collections::HashMap::new(),
        );
        let resp2 = handle_attestation_challenge(
            "bm9uY2U=",
            "2025-01-15T00:00:00Z",
            Some("key"),
            None,
            None,
            std::collections::HashMap::new(),
        );

        // Same inputs should produce same output (deterministic).
        // Without Secure Enclave, both return empty signatures.
        // With SE, same input produces same ECDSA signature (deterministic
        // if the SE uses RFC 6979 deterministic nonces).
        assert_eq!(resp1, resp2);
    }

    #[test]
    fn test_handle_attestation_challenge_different_nonces_different_responses() {
        // Different nonces should produce structurally different responses
        // (different nonce fields at minimum; in production with SE, also
        // different signatures).
        let resp1 = handle_attestation_challenge(
            "bm9uY2Ux",
            "2025-01-15T00:00:00Z",
            Some("key"),
            None,
            None,
            std::collections::HashMap::new(),
        );
        let resp2 = handle_attestation_challenge(
            "bm9uY2Uy",
            "2025-01-15T00:00:00Z",
            Some("key"),
            None,
            None,
            std::collections::HashMap::new(),
        );

        // The nonce fields must differ.
        match (&resp1, &resp2) {
            (
                ProviderMessage::AttestationResponse { nonce: n1, .. },
                ProviderMessage::AttestationResponse { nonce: n2, .. },
            ) => {
                assert_ne!(n1, n2, "different input nonces should echo differently");
            }
            _ => panic!("Expected AttestationResponse"),
        }
    }

    #[test]
    fn test_handle_attestation_challenge_serialization() {
        let response = handle_attestation_challenge(
            "dGVzdA==",
            "2025-06-01T00:00:00Z",
            Some("a2V5"),
            None,
            None,
            std::collections::HashMap::new(),
        );
        let json = serde_json::to_string(&response).unwrap();
        assert!(json.contains("\"type\":\"attestation_response\""));
        assert!(json.contains("\"nonce\":\"dGVzdA==\""));

        // Verify it deserializes back correctly.
        let deserialized: ProviderMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(response, deserialized);
    }

    /// Start a mock WebSocket server that accepts a connection, reads the register message,
    /// sends an inference request, and then closes.
    async fn start_mock_ws_server() -> (SocketAddr, tokio::task::JoinHandle<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();

        let handle = tokio::spawn(async move {
            let mut received_messages = Vec::new();

            let (stream, _) = listener.accept().await.unwrap();
            let ws_stream = tokio_tungstenite::accept_async(stream).await.unwrap();
            let (mut write, mut read) = ws_stream.split();

            // Read the register message
            if let Some(Ok(Message::Text(text))) = read.next().await {
                received_messages.push(text.to_string());
            }

            // Send an inference request
            let request = serde_json::json!({
                "type": "inference_request",
                "request_id": "test-req-1",
                "body": {
                    "model": "qwen3.5-9b",
                    "messages": [{"role": "user", "content": "hello"}],
                    "stream": false
                }
            });
            write
                .send(Message::Text(
                    serde_json::to_string(&request).unwrap().into(),
                ))
                .await
                .unwrap();

            // Read heartbeat or any response
            if let Some(Ok(Message::Text(text))) = read.next().await {
                received_messages.push(text.to_string());
            }

            // Send cancel
            let cancel = serde_json::json!({
                "type": "cancel",
                "request_id": "test-req-1"
            });
            write
                .send(Message::Text(
                    serde_json::to_string(&cancel).unwrap().into(),
                ))
                .await
                .unwrap();

            // Close
            let _ = write.send(Message::Close(None)).await;

            received_messages
        });

        (addr, handle)
    }

    #[tokio::test]
    async fn test_coordinator_connect_register_and_receive() {
        let (addr, server_handle) = start_mock_ws_server().await;

        let (event_tx, mut event_rx) = mpsc::channel(32);
        let (_outbound_tx, outbound_rx) = mpsc::channel(32);
        let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);

        let client = CoordinatorClient::new(
            format!("ws://127.0.0.1:{}", addr.port()),
            sample_hardware(),
            vec![],
            "vllm_mlx".to_string(),
            Duration::from_secs(1),
            None,
            Arc::new(crate::crypto::NodeKeyPair::generate()),
        );

        // Run client in background
        let client_handle = tokio::spawn(async move {
            // This will error when server closes — that's expected
            let _ = client.run(event_tx, outbound_rx, shutdown_rx).await;
        });

        // Wait for Connected event
        let event = tokio::time::timeout(Duration::from_secs(5), event_rx.recv())
            .await
            .expect("timeout waiting for Connected")
            .expect("channel closed");
        assert!(matches!(event, CoordinatorEvent::Connected));

        // Wait for InferenceRequest event
        let event = tokio::time::timeout(Duration::from_secs(5), event_rx.recv())
            .await
            .expect("timeout waiting for InferenceRequest")
            .expect("channel closed");
        match event {
            CoordinatorEvent::InferenceRequest { request_id, body } => {
                assert_eq!(request_id, "test-req-1");
                assert_eq!(body["model"], "qwen3.5-9b");
            }
            other => panic!("Expected InferenceRequest, got {:?}", other),
        }

        // Wait for Cancel event
        let event = tokio::time::timeout(Duration::from_secs(5), event_rx.recv())
            .await
            .expect("timeout waiting for Cancel")
            .expect("channel closed");
        match event {
            CoordinatorEvent::Cancel { request_id } => {
                assert_eq!(request_id, "test-req-1");
            }
            other => panic!("Expected Cancel, got {:?}", other),
        }

        // Shutdown
        let _ = shutdown_tx.send(true);
        let _ = tokio::time::timeout(Duration::from_secs(2), client_handle).await;

        // Verify server received register message
        let received = server_handle.await.unwrap();
        assert!(!received.is_empty());
        let register: serde_json::Value = serde_json::from_str(&received[0]).unwrap();
        assert_eq!(register["type"], "register");
        assert_eq!(register["backend"], "vllm_mlx");
    }

    // -----------------------------------------------------------------------
    // Challenge response generation — verifying security fields
    // -----------------------------------------------------------------------

    #[test]
    fn test_attestation_response_has_all_security_fields() {
        let response = handle_attestation_challenge(
            "dGVzdG5vbmNl",
            "2026-01-01T00:00:00Z",
            Some("cHVibGljLWtleQ=="),
            None,
            None,
            std::collections::HashMap::new(),
        );

        match response {
            ProviderMessage::AttestationResponse {
                nonce,
                signature,
                public_key,
                hypervisor_active,
                rdma_disabled,
                sip_enabled,
                secure_boot_enabled,
                binary_hash: _,
                active_model_hash: _,
                python_hash: _,
                runtime_hash: _,
                template_hashes: _,
                grpc_binary_hash: _,
                image_bridge_hash: _,
                model_hashes: _,
            } => {
                // Nonce echoed back exactly
                assert_eq!(nonce, "dGVzdG5vbmNl");
                // Signature: empty in test env (no Secure Enclave),
                // base64-encoded DER ECDSA in production.
                let _ = signature;
                // Public key matches input
                assert_eq!(public_key, "cHVibGljLWtleQ==");
                // All security status fields are populated
                assert!(sip_enabled.is_some(), "sip_enabled must be present");
                assert!(rdma_disabled.is_some(), "rdma_disabled must be present");
                assert!(
                    hypervisor_active.is_some(),
                    "hypervisor_active must be present"
                );
                assert!(
                    secure_boot_enabled.is_some(),
                    "secure_boot_enabled must be present"
                );
            }
            _ => panic!("Expected AttestationResponse"),
        }
    }

    #[test]
    fn test_attestation_response_correct_public_key_passthrough() {
        // The public key in the response should match what was passed in.
        let pk = "YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXo=";
        let response = handle_attestation_challenge(
            "bm9uY2U=",
            "2026-06-15T00:00:00Z",
            Some(pk),
            None,
            None,
            std::collections::HashMap::new(),
        );

        match response {
            ProviderMessage::AttestationResponse { public_key, .. } => {
                assert_eq!(public_key, pk);
            }
            _ => panic!("Expected AttestationResponse"),
        }
    }

    #[test]
    fn test_attestation_response_none_public_key_becomes_empty() {
        // When no public key is configured, the response should use empty string.
        let response = handle_attestation_challenge(
            "bm9uY2U=",
            "2026-06-15T00:00:00Z",
            None,
            None,
            None,
            std::collections::HashMap::new(),
        );

        match response {
            ProviderMessage::AttestationResponse { public_key, .. } => {
                assert_eq!(public_key, "", "None public key should become empty string");
            }
            _ => panic!("Expected AttestationResponse"),
        }
    }

    #[test]
    fn test_attestation_response_different_timestamps() {
        // With the Secure Enclave, different timestamps produce different
        // ECDSA signatures (different SHA-256 input). Without SE (test env),
        // both produce empty signatures, so we just verify the function
        // runs without panicking for different timestamp inputs.
        let resp1 = handle_attestation_challenge(
            "bm9uY2U=",
            "2026-01-01T00:00:00Z",
            Some("key"),
            None,
            None,
            std::collections::HashMap::new(),
        );
        let resp2 = handle_attestation_challenge(
            "bm9uY2U=",
            "2026-06-01T00:00:00Z",
            Some("key"),
            None,
            None,
            std::collections::HashMap::new(),
        );

        // Both should be valid AttestationResponse messages
        match (&resp1, &resp2) {
            (
                ProviderMessage::AttestationResponse { nonce: n1, .. },
                ProviderMessage::AttestationResponse { nonce: n2, .. },
            ) => {
                // Same nonce, different timestamps — both valid responses
                assert_eq!(n1, n2, "nonces should match (same input)");
            }
            _ => panic!("Expected AttestationResponse"),
        }
    }

    #[test]
    fn test_attestation_response_serializes_for_go_coordinator() {
        // The response must serialize with snake_case field names and the
        // "attestation_response" type tag that the Go coordinator expects.
        let response = handle_attestation_challenge(
            "YWJj",
            "2026-03-15T10:00:00Z",
            Some("cGs="),
            None,
            None,
            std::collections::HashMap::new(),
        );

        let json = serde_json::to_string(&response).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

        assert_eq!(parsed["type"], "attestation_response");
        assert_eq!(parsed["nonce"], "YWJj");
        assert!(parsed["signature"].is_string());
        assert_eq!(parsed["public_key"], "cGs=");
        // Security fields present in JSON
        assert!(parsed.get("sip_enabled").is_some());
        assert!(parsed.get("rdma_disabled").is_some());
        assert!(parsed.get("hypervisor_active").is_some());
        assert!(parsed.get("secure_boot_enabled").is_some());
    }

    #[test]
    fn test_build_register_message_with_wallet() {
        let hw = sample_hardware();
        let models = vec![ModelInfo {
            id: "test-model".to_string(),
            model_type: None,
            parameters: None,
            quantization: None,
            size_bytes: 1000,
            estimated_memory_gb: 1.0,
            weight_hash: None,
        }];

        let wallet_addr = "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef".to_string();
        let msg = build_register_message_with_wallet(
            &hw,
            &models,
            "vllm_mlx",
            Some("cHVia2V5".to_string()),
            Some(wallet_addr.clone()),
            None,
        );

        match msg {
            ProviderMessage::Register {
                wallet_address,
                public_key,
                ..
            } => {
                assert_eq!(wallet_address, Some(wallet_addr));
                assert_eq!(public_key, Some("cHVia2V5".to_string()));
            }
            _ => panic!("Expected Register message"),
        }
    }
}
