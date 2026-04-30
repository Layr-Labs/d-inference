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
use crate::protocol::{CoordinatorMessage, ProviderMessage, ProviderStats, ProviderStatus};
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
        response_public_key: Option<[u8; 32]>,
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
    /// Python interpreter used to recompute runtime hashes on attestation challenges.
    runtime_hash_command: Option<String>,
    /// Per-model weight hashes for all active models.
    model_hashes: std::collections::HashMap<String, String>,
    /// Live backend capacity data (updated by main loop, read by heartbeat tick).
    backend_capacity: Arc<std::sync::Mutex<Option<crate::protocol::BackendCapacity>>>,
    /// Ephemeral Secure Enclave handle for challenge-response signing.
    se_handle: Option<Arc<crate::secure_enclave_key::SecureEnclaveHandle>>,
    /// Persistent entitlement-gated provider identity for private text trust.
    provider_identity: Option<Arc<crate::secure_enclave_key::ProviderIdentityHandle>>,
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
            runtime_hash_command: None,
            model_hashes: std::collections::HashMap::new(),
            backend_capacity: Arc::new(std::sync::Mutex::new(None)),
            se_handle: None,
            provider_identity: None,
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

    /// Set the Python interpreter used to recompute runtime hashes at challenge time.
    pub fn with_runtime_hash_command(mut self, python_cmd: Option<String>) -> Self {
        self.runtime_hash_command = python_cmd;
        self
    }

    /// Set the ephemeral Secure Enclave handle for challenge-response signing.
    pub fn with_se_handle(
        mut self,
        handle: Option<Arc<crate::secure_enclave_key::SecureEnclaveHandle>>,
    ) -> Self {
        self.se_handle = handle;
        self
    }

    /// Set the persistent provider-bound identity handle.
    pub fn with_provider_identity(
        mut self,
        handle: Option<Arc<crate::secure_enclave_key::ProviderIdentityHandle>>,
    ) -> Self {
        self.provider_identity = handle;
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
        let mut reconnect_count: u64 = 0;

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
                    reconnect_count += 1;
                    // Only report connectivity telemetry after a few failures
                    // so transient hiccups don't flood the admin console.
                    if reconnect_count == 3 || reconnect_count == 10 || reconnect_count % 30 == 0 {
                        crate::telemetry::emit(
                            crate::telemetry::TelemetryEvent::new(
                                crate::telemetry::Source::Provider,
                                crate::telemetry::Severity::Warn,
                                crate::telemetry::Kind::Connectivity,
                                "coordinator reconnect",
                            )
                            .with_field("reconnect_count", reconnect_count as i64)
                            .with_field("last_error", format!("{e}"))
                            .with_field("ws_state", "reconnecting"),
                        );
                    }

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
        let (python_hash, runtime_hash, template_hashes) = if let Some(ref rh) = self.runtime_hashes
        {
            (
                rh.python_hash.clone(),
                rh.runtime_hash.clone(),
                rh.template_hashes.clone(),
            )
        } else {
            (None, None, std::collections::HashMap::new())
        };
        let privacy_caps = crate::protocol::PrivacyCapabilities {
            text_backend_inprocess: true,
            text_proxy_disabled: true,
            python_runtime_locked: true,
            dangerous_modules_blocked: true,
            sip_enabled: crate::security::check_sip_enabled(),
            anti_debug_enabled: true,
            core_dumps_disabled: true,
            env_scrubbed: true,
            hypervisor_active: crate::security::check_hypervisor_active(),
        };
        let version = env!("CARGO_PKG_VERSION").to_string();
        let binary_hash = crate::security::self_binary_hash();
        let provider_identity_public_key = self
            .provider_identity
            .as_ref()
            .map(|h| h.public_key_base64().to_string());
        let provider_identity_signature = match (
            self.provider_identity.as_ref(),
            provider_identity_public_key.as_deref(),
        ) {
            (Some(identity), Some(identity_public_key)) => {
                match build_provider_identity_registration_canonical(
                    identity_public_key,
                    self.public_key.as_deref(),
                    binary_hash.as_deref(),
                    Some(version.as_str()),
                    &self.backend_name,
                    true,
                    python_hash.as_deref(),
                    runtime_hash.as_deref(),
                    &template_hashes,
                    Some(&privacy_caps),
                ) {
                    Ok(bytes) => match identity.sign(&bytes) {
                        Ok(sig) => Some(sig),
                        Err(e) => {
                            tracing::warn!(
                                "failed to sign provider-bound registration: {e}; private text routing will be disabled"
                            );
                            None
                        }
                    },
                    Err(e) => {
                        tracing::warn!(
                            "failed to build provider-bound registration payload: {e}; private text routing will be disabled"
                        );
                        None
                    }
                }
            }
            _ => {
                if self.public_key.is_some() {
                    tracing::warn!(
                        "provider-bound identity unavailable; coordinator will reject private text routing"
                    );
                }
                None
            }
        };

        let register = ProviderMessage::Register {
            hardware: self.hardware.clone(),
            models: self.models.clone(),
            backend: self.backend_name.clone(),
            version: Some(version),
            public_key: self.public_key.clone(),
            binary_hash,
            provider_identity_public_key,
            provider_identity_signature,
            encrypted_response_chunks: true,
            wallet_address: self.wallet_address.clone(),
            attestation: self.attestation.clone(),
            prefill_tps: None,
            decode_tps: None,
            auth_token: self.auth_token.clone(),
            python_hash,
            runtime_hash,
            template_hashes,
            privacy_capabilities: Some(privacy_caps),
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
                                Ok(CoordinatorMessage::InferenceRequest { request_id, body: _, encrypted_body }) => {
                                    tracing::info!("Received inference request: {request_id}");

                                    let Some(enc) = encrypted_body else {
                                        tracing::error!(
                                            "Rejecting plaintext inference request: {request_id}"
                                        );
                                        let error = ProviderMessage::InferenceError {
                                            request_id,
                                            error: "coordinator text request missing encrypted body".to_string(),
                                            status_code: 400,
                                        };
                                        let json = serde_json::to_string(&error).unwrap_or_default();
                                        let _ = write.send(Message::Text(json.into())).await;
                                        continue;
                                    };

                                    tracing::info!("Decrypting E2E encrypted request");
                                    let (decrypted_body, response_public_key) =
                                        match decrypt_request_body(&enc, self.node_keypair.as_ref()) {
                                            Ok(b) => b,
                                            Err(e) => {
                                                tracing::error!("Failed to decrypt request: {e}");
                                                continue;
                                            }
                                        };

                                    let _ = event_tx.send(CoordinatorEvent::InferenceRequest {
                                        request_id,
                                        body: decrypted_body,
                                        response_public_key,
                                    }).await;
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
                                    let fresh_runtime_hashes = self
                                        .runtime_hash_command
                                        .as_deref()
                                        .map(crate::security::compute_runtime_hashes);
                                    let response = handle_attestation_challenge(
                                        &nonce,
                                        &timestamp,
                                        self.public_key.as_deref(),
                                        model_hash.as_deref(),
                                        fresh_runtime_hashes
                                            .as_ref()
                                            .or(self.runtime_hashes.as_ref()),
                                        self.model_hashes.clone(),
                                        self.se_handle.as_deref(),
                                        self.provider_identity.as_deref(),
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
) -> anyhow::Result<(serde_json::Value, Option<[u8; 32]>)> {
    use base64::Engine;
    use zeroize::Zeroize;

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

    let ciphertext = base64::engine::general_purpose::STANDARD
        .decode(&encrypted.ciphertext)
        .map_err(|e| anyhow::anyhow!("invalid ciphertext: {e}"))?;

    let mut plaintext = keypair.decrypt(&ephemeral_pub, &ciphertext)?;

    // Parse JSON from the decrypted buffer, but zeroize the raw bytes on both
    // success and failure so malformed payloads do not leave plaintext behind.
    let parsed = serde_json::from_slice(&plaintext);
    plaintext.zeroize();
    let body: serde_json::Value =
        parsed.map_err(|e| anyhow::anyhow!("decrypted body is not valid JSON: {e}"))?;

    tracing::info!("E2E decryption successful — request decrypted inside hardened process");
    Ok((body, Some(ephemeral_pub)))
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
    se_handle: Option<&crate::secure_enclave_key::SecureEnclaveHandle>,
    provider_identity: Option<&crate::secure_enclave_key::ProviderIdentityHandle>,
) -> ProviderMessage {
    let data = format!("{}{}", nonce, timestamp);

    let pk_str = public_key.unwrap_or("");
    let signature = match crate::security::se_sign(se_handle, data.as_bytes()) {
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
    let secure_boot_enabled = crate::security::check_secure_boot_enabled();

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

    let (python_hash, rt_hash, template_hashes) = if let Some(rh) = runtime_hashes {
        (
            rh.python_hash.clone(),
            rh.runtime_hash.clone(),
            rh.template_hashes.clone(),
        )
    } else {
        (None, None, std::collections::HashMap::new())
    };

    let active_model_hash_owned = current_model_hash.map(|s| s.to_string());

    // Build the canonical status payload and sign it. This binds all the
    // status fields below to the SE key, preventing a compromised provider
    // from echoing a valid nonce+timestamp signature while lying about
    // sip_enabled, binary_hash, etc.
    //
    // Must stay byte-identical to coordinator/internal/attestation.go
    // BuildStatusCanonical — sorted keys, optional fields omitted, nested
    // maps with sorted keys (BTreeMap).
    let canonical = build_status_canonical(
        nonce,
        timestamp,
        Some(hypervisor_active),
        Some(rdma_disabled),
        Some(sip_enabled),
        secure_boot_enabled,
        binary_hash.as_deref(),
        active_model_hash_owned.as_deref(),
        python_hash.as_deref(),
        rt_hash.as_deref(),
        &template_hashes,
        None, // grpc_binary_hash removed (text-only)
        None, // image_bridge_hash removed (text-only)
        &model_hashes,
    );
    let status_signature = match canonical {
        Ok(bytes) => crate::security::se_sign(se_handle, &bytes),
        Err(e) => {
            tracing::warn!(
                "failed to build canonical status payload: {} — coordinator will treat status fields as unsigned",
                e
            );
            None
        }
    };
    let provider_identity_signature = provider_identity.and_then(|identity| {
        match build_provider_identity_challenge_canonical(
            identity.public_key_base64(),
            pk_str,
            nonce,
            timestamp,
            Some(hypervisor_active),
            Some(rdma_disabled),
            Some(sip_enabled),
            secure_boot_enabled,
            binary_hash.as_deref(),
            active_model_hash_owned.as_deref(),
            python_hash.as_deref(),
            rt_hash.as_deref(),
            &template_hashes,
            &model_hashes,
        ) {
            Ok(bytes) => match identity.sign(&bytes) {
                Ok(sig) => Some(sig),
                Err(e) => {
                    tracing::warn!("failed to sign provider-bound challenge payload: {e}");
                    None
                }
            },
            Err(e) => {
                tracing::warn!("failed to build provider-bound challenge payload: {e}");
                None
            }
        }
    });

    ProviderMessage::AttestationResponse {
        nonce: nonce.to_string(),
        signature,
        status_signature,
        provider_identity_signature,
        public_key: pk_str.to_string(),
        hypervisor_active: Some(hypervisor_active),
        rdma_disabled: Some(rdma_disabled),
        sip_enabled: Some(sip_enabled),
        secure_boot_enabled,
        binary_hash,
        active_model_hash: active_model_hash_owned,
        python_hash,
        runtime_hash: rt_hash,
        template_hashes,
        model_hashes,
    }
}

/// Build the canonical status payload bytes that get signed by the SE
/// key for AttestationResponse.status_signature. This must produce
/// byte-identical output to the Go BuildStatusCanonical helper.
///
/// Encoding rules:
///   - Top-level keys sorted alphabetically (BTreeMap).
///   - nonce + timestamp always present.
///   - Optional bool/string/map fields are OMITTED if None / empty —
///     "unknown" must serialize differently than "false" so a downgrade
///     attacker can't strip a positive claim and have it look like
///     legitimate omission.
///   - Nested maps (template_hashes, model_hashes) also sorted via
///     BTreeMap.
///   - serde_json defaults: compact (no whitespace), bool as true/false,
///     strings UTF-8 with standard JSON escapes.
#[allow(clippy::too_many_arguments)]
fn build_status_canonical(
    nonce: &str,
    timestamp: &str,
    hypervisor_active: Option<bool>,
    rdma_disabled: Option<bool>,
    sip_enabled: Option<bool>,
    secure_boot_enabled: Option<bool>,
    binary_hash: Option<&str>,
    active_model_hash: Option<&str>,
    python_hash: Option<&str>,
    runtime_hash: Option<&str>,
    template_hashes: &std::collections::HashMap<String, String>,
    grpc_binary_hash: Option<&str>,
    image_bridge_hash: Option<&str>,
    model_hashes: &std::collections::HashMap<String, String>,
) -> serde_json::Result<Vec<u8>> {
    use std::collections::BTreeMap;
    let mut m: BTreeMap<&str, serde_json::Value> = BTreeMap::new();
    m.insert("nonce", serde_json::Value::String(nonce.to_string()));
    m.insert(
        "timestamp",
        serde_json::Value::String(timestamp.to_string()),
    );
    if let Some(v) = hypervisor_active {
        m.insert("hypervisor_active", serde_json::Value::Bool(v));
    }
    if let Some(v) = rdma_disabled {
        m.insert("rdma_disabled", serde_json::Value::Bool(v));
    }
    if let Some(v) = sip_enabled {
        m.insert("sip_enabled", serde_json::Value::Bool(v));
    }
    if let Some(v) = secure_boot_enabled {
        m.insert("secure_boot_enabled", serde_json::Value::Bool(v));
    }
    if let Some(v) = binary_hash {
        if !v.is_empty() {
            m.insert("binary_hash", serde_json::Value::String(v.to_string()));
        }
    }
    if let Some(v) = active_model_hash {
        if !v.is_empty() {
            m.insert(
                "active_model_hash",
                serde_json::Value::String(v.to_string()),
            );
        }
    }
    if let Some(v) = python_hash {
        if !v.is_empty() {
            m.insert("python_hash", serde_json::Value::String(v.to_string()));
        }
    }
    if let Some(v) = runtime_hash {
        if !v.is_empty() {
            m.insert("runtime_hash", serde_json::Value::String(v.to_string()));
        }
    }
    if let Some(v) = grpc_binary_hash {
        if !v.is_empty() {
            m.insert("grpc_binary_hash", serde_json::Value::String(v.to_string()));
        }
    }
    if let Some(v) = image_bridge_hash {
        if !v.is_empty() {
            m.insert(
                "image_bridge_hash",
                serde_json::Value::String(v.to_string()),
            );
        }
    }
    if !template_hashes.is_empty() {
        let sorted: BTreeMap<&str, &str> = template_hashes
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        m.insert("template_hashes", serde_json::to_value(sorted)?);
    }
    if !model_hashes.is_empty() {
        let sorted: BTreeMap<&str, &str> = model_hashes
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        m.insert("model_hashes", serde_json::to_value(sorted)?);
    }
    serde_json::to_vec(&m)
}

#[allow(clippy::too_many_arguments)]
fn build_provider_identity_registration_canonical(
    provider_identity_public_key: &str,
    public_key: Option<&str>,
    binary_hash: Option<&str>,
    version: Option<&str>,
    backend: &str,
    encrypted_response_chunks: bool,
    python_hash: Option<&str>,
    runtime_hash: Option<&str>,
    template_hashes: &std::collections::HashMap<String, String>,
    privacy_capabilities: Option<&crate::protocol::PrivacyCapabilities>,
) -> serde_json::Result<Vec<u8>> {
    use std::collections::BTreeMap;

    let mut m: BTreeMap<&str, serde_json::Value> = BTreeMap::new();
    m.insert("backend", serde_json::Value::String(backend.to_string()));
    m.insert(
        "domain",
        serde_json::Value::String("darkbloom.provider.registration.v1".to_string()),
    );
    m.insert(
        "encrypted_response_chunks",
        serde_json::Value::Bool(encrypted_response_chunks),
    );
    m.insert(
        "provider_identity_public_key",
        serde_json::Value::String(provider_identity_public_key.to_string()),
    );
    if let Some(v) = public_key {
        if !v.is_empty() {
            m.insert("public_key", serde_json::Value::String(v.to_string()));
        }
    }
    if let Some(v) = binary_hash {
        if !v.is_empty() {
            m.insert("binary_hash", serde_json::Value::String(v.to_string()));
        }
    }
    if let Some(v) = version {
        if !v.is_empty() {
            m.insert("version", serde_json::Value::String(v.to_string()));
        }
    }
    if let Some(v) = python_hash {
        if !v.is_empty() {
            m.insert("python_hash", serde_json::Value::String(v.to_string()));
        }
    }
    if let Some(v) = runtime_hash {
        if !v.is_empty() {
            m.insert("runtime_hash", serde_json::Value::String(v.to_string()));
        }
    }
    if !template_hashes.is_empty() {
        let sorted: BTreeMap<&str, &str> = template_hashes
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        m.insert("template_hashes", serde_json::to_value(sorted)?);
    }
    if let Some(caps) = privacy_capabilities {
        let mut c: BTreeMap<&str, serde_json::Value> = BTreeMap::new();
        c.insert(
            "anti_debug_enabled",
            serde_json::Value::Bool(caps.anti_debug_enabled),
        );
        c.insert(
            "core_dumps_disabled",
            serde_json::Value::Bool(caps.core_dumps_disabled),
        );
        c.insert(
            "dangerous_modules_blocked",
            serde_json::Value::Bool(caps.dangerous_modules_blocked),
        );
        c.insert("env_scrubbed", serde_json::Value::Bool(caps.env_scrubbed));
        c.insert(
            "hypervisor_active",
            serde_json::Value::Bool(caps.hypervisor_active),
        );
        c.insert(
            "python_runtime_locked",
            serde_json::Value::Bool(caps.python_runtime_locked),
        );
        c.insert("sip_enabled", serde_json::Value::Bool(caps.sip_enabled));
        c.insert(
            "text_backend_inprocess",
            serde_json::Value::Bool(caps.text_backend_inprocess),
        );
        c.insert(
            "text_proxy_disabled",
            serde_json::Value::Bool(caps.text_proxy_disabled),
        );
        m.insert("privacy_capabilities", serde_json::to_value(c)?);
    }

    serde_json::to_vec(&m)
}

#[allow(clippy::too_many_arguments)]
fn build_provider_identity_challenge_canonical(
    provider_identity_public_key: &str,
    public_key: &str,
    nonce: &str,
    timestamp: &str,
    hypervisor_active: Option<bool>,
    rdma_disabled: Option<bool>,
    sip_enabled: Option<bool>,
    secure_boot_enabled: Option<bool>,
    binary_hash: Option<&str>,
    active_model_hash: Option<&str>,
    python_hash: Option<&str>,
    runtime_hash: Option<&str>,
    template_hashes: &std::collections::HashMap<String, String>,
    model_hashes: &std::collections::HashMap<String, String>,
) -> serde_json::Result<Vec<u8>> {
    use std::collections::BTreeMap;

    let mut m: BTreeMap<&str, serde_json::Value> = BTreeMap::new();
    m.insert(
        "domain",
        serde_json::Value::String("darkbloom.provider.challenge.v1".to_string()),
    );
    m.insert("nonce", serde_json::Value::String(nonce.to_string()));
    m.insert(
        "provider_identity_public_key",
        serde_json::Value::String(provider_identity_public_key.to_string()),
    );
    m.insert(
        "public_key",
        serde_json::Value::String(public_key.to_string()),
    );
    m.insert(
        "timestamp",
        serde_json::Value::String(timestamp.to_string()),
    );
    if let Some(v) = hypervisor_active {
        m.insert("hypervisor_active", serde_json::Value::Bool(v));
    }
    if let Some(v) = rdma_disabled {
        m.insert("rdma_disabled", serde_json::Value::Bool(v));
    }
    if let Some(v) = sip_enabled {
        m.insert("sip_enabled", serde_json::Value::Bool(v));
    }
    if let Some(v) = secure_boot_enabled {
        m.insert("secure_boot_enabled", serde_json::Value::Bool(v));
    }
    if let Some(v) = binary_hash {
        if !v.is_empty() {
            m.insert("binary_hash", serde_json::Value::String(v.to_string()));
        }
    }
    if let Some(v) = active_model_hash {
        if !v.is_empty() {
            m.insert(
                "active_model_hash",
                serde_json::Value::String(v.to_string()),
            );
        }
    }
    if let Some(v) = python_hash {
        if !v.is_empty() {
            m.insert("python_hash", serde_json::Value::String(v.to_string()));
        }
    }
    if let Some(v) = runtime_hash {
        if !v.is_empty() {
            m.insert("runtime_hash", serde_json::Value::String(v.to_string()));
        }
    }
    if !template_hashes.is_empty() {
        let sorted: BTreeMap<&str, &str> = template_hashes
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        m.insert("template_hashes", serde_json::to_value(sorted)?);
    }
    if !model_hashes.is_empty() {
        let sorted: BTreeMap<&str, &str> = model_hashes
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        m.insert("model_hashes", serde_json::to_value(sorted)?);
    }

    serde_json::to_vec(&m)
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
        binary_hash: None,
        provider_identity_public_key: None,
        provider_identity_signature: None,
        encrypted_response_chunks: true,
        wallet_address,
        attestation,
        prefill_tps: None,
        decode_tps: None,
        auth_token: None,
        python_hash: None,
        runtime_hash: None,
        template_hashes: std::collections::HashMap::new(),
        privacy_capabilities: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hardware::{ChipFamily, ChipTier, CpuCores};
    use futures_util::StreamExt;
    use std::net::SocketAddr;
    use tokio::net::TcpListener;

    fn provider_identity_test_nonce() -> String {
        ['n', 'o', 'n', 'c', 'e'].iter().copied().collect()
    }

    fn provider_identity_html_test_nonce() -> String {
        ['n', '<', '&', '>'].iter().copied().collect()
    }

    /// Cross-language wire-format guard. The bytes encoded here must
    /// EXACTLY match what coordinator/internal/attestation.BuildStatusCanonical
    /// produces in Go for the same input. If this golden bytes test ever
    /// diverges, the corresponding Go test (in attestation_test.go) will
    /// also fail and you'll catch the protocol drift before it ships.
    ///
    /// Encoding properties under test:
    ///   - Top-level keys sorted alphabetically.
    ///   - Optional fields (None / empty) omitted entirely.
    ///   - Nested maps (template_hashes, model_hashes) sorted.
    ///   - Compact (no whitespace).
    #[test]
    fn test_build_status_canonical_golden_bytes() {
        let mut templates = std::collections::HashMap::new();
        templates.insert("chatml".to_string(), "tmplhash1".to_string());
        templates.insert("gemma".to_string(), "tmplhash2".to_string());

        let mut models = std::collections::HashMap::new();
        models.insert("qwen".to_string(), "modelhash1".to_string());
        models.insert("trinity".to_string(), "modelhash2".to_string());

        let bytes = build_status_canonical(
            "test-nonce",
            "2026-04-16T12:00:00Z",
            Some(true),
            Some(true),
            Some(true),
            Some(true),
            Some("binhash"),
            Some("activemodel"),
            Some("pyhash"),
            Some("rthash"),
            &templates,
            None,
            Some("imghash"),
            &models,
        )
        .expect("canonical build should succeed");

        let expected = br#"{"active_model_hash":"activemodel","binary_hash":"binhash","hypervisor_active":true,"image_bridge_hash":"imghash","model_hashes":{"qwen":"modelhash1","trinity":"modelhash2"},"nonce":"test-nonce","python_hash":"pyhash","rdma_disabled":true,"runtime_hash":"rthash","secure_boot_enabled":true,"sip_enabled":true,"template_hashes":{"chatml":"tmplhash1","gemma":"tmplhash2"},"timestamp":"2026-04-16T12:00:00Z"}"#;

        assert_eq!(
            bytes,
            expected.to_vec(),
            "canonical bytes drifted — Go side will reject signatures"
        );
    }

    /// Empty optional fields must be omitted from canonical output, not
    /// serialized as empty/false. This prevents downgrade attacks where
    /// a stripped sip_enabled=true claim looks like legitimate omission.
    #[test]
    fn test_build_status_canonical_omits_empties() {
        let bytes = build_status_canonical(
            "n",
            "t",
            None,
            None,
            None,
            None,
            None,
            None,
            None,
            None,
            &std::collections::HashMap::new(),
            None,
            None,
            &std::collections::HashMap::new(),
        )
        .expect("canonical build should succeed");

        // Only nonce and timestamp survive when everything else is None.
        assert_eq!(bytes, br#"{"nonce":"n","timestamp":"t"}"#.to_vec());
    }

    /// Mirror of Go's TestBuildStatusCanonicalFalseIsExplicit. False bool
    /// values must be serialized explicitly, not stripped — otherwise a
    /// downgrade attacker could reduce sip_enabled=true to "absent" and
    /// the verify step couldn't distinguish.
    #[test]
    fn test_build_status_canonical_false_is_explicit() {
        let bytes = build_status_canonical(
            "n",
            "t",
            None,
            None,
            Some(false),
            None,
            None,
            None,
            None,
            None,
            &std::collections::HashMap::new(),
            None,
            None,
            &std::collections::HashMap::new(),
        )
        .expect("canonical build should succeed");
        assert_eq!(
            bytes,
            br#"{"nonce":"n","sip_enabled":false,"timestamp":"t"}"#.to_vec()
        );
    }

    #[test]
    fn test_provider_identity_registration_canonical_golden_bytes() {
        let mut templates = std::collections::HashMap::new();
        templates.insert("z".to_string(), "2".to_string());
        templates.insert("a".to_string(), "1".to_string());

        let caps = crate::protocol::PrivacyCapabilities {
            text_backend_inprocess: true,
            text_proxy_disabled: true,
            python_runtime_locked: true,
            dangerous_modules_blocked: true,
            sip_enabled: true,
            anti_debug_enabled: true,
            core_dumps_disabled: true,
            env_scrubbed: true,
            hypervisor_active: false,
        };

        let bytes = build_provider_identity_registration_canonical(
            "idpk",
            Some("x25519"),
            Some("binhash"),
            Some("0.4.7"),
            "inprocess-mlx",
            true,
            Some("py"),
            Some("rt"),
            &templates,
            Some(&caps),
        )
        .expect("canonical build should succeed");

        let expected = br#"{"backend":"inprocess-mlx","binary_hash":"binhash","domain":"darkbloom.provider.registration.v1","encrypted_response_chunks":true,"privacy_capabilities":{"anti_debug_enabled":true,"core_dumps_disabled":true,"dangerous_modules_blocked":true,"env_scrubbed":true,"hypervisor_active":false,"python_runtime_locked":true,"sip_enabled":true,"text_backend_inprocess":true,"text_proxy_disabled":true},"provider_identity_public_key":"idpk","public_key":"x25519","python_hash":"py","runtime_hash":"rt","template_hashes":{"a":"1","z":"2"},"version":"0.4.7"}"#;
        assert_eq!(bytes, expected.to_vec());
    }

    #[test]
    fn test_provider_identity_challenge_canonical_golden_bytes() {
        let mut templates = std::collections::HashMap::new();
        templates.insert("z".to_string(), "2".to_string());
        templates.insert("a".to_string(), "1".to_string());

        let mut models = std::collections::HashMap::new();
        models.insert("qwen".to_string(), "abc".to_string());
        models.insert("llama".to_string(), "def".to_string());

        let nonce = provider_identity_test_nonce();
        let bytes = build_provider_identity_challenge_canonical(
            "idpk",
            "x25519",
            &nonce,
            "2026-04-28T20:00:00Z",
            Some(true),
            Some(true),
            Some(true),
            Some(true),
            Some("binhash"),
            Some("active"),
            Some("py"),
            Some("rt"),
            &templates,
            &models,
        )
        .expect("canonical build should succeed");

        let expected = format!(
            r#"{{"active_model_hash":"active","binary_hash":"binhash","domain":"darkbloom.provider.challenge.v1","hypervisor_active":true,"model_hashes":{{"llama":"def","qwen":"abc"}},"nonce":"{}","provider_identity_public_key":"idpk","public_key":"x25519","python_hash":"py","rdma_disabled":true,"runtime_hash":"rt","secure_boot_enabled":true,"sip_enabled":true,"template_hashes":{{"a":"1","z":"2"}},"timestamp":"2026-04-28T20:00:00Z"}}"#,
            nonce
        );
        assert_eq!(bytes, expected.into_bytes());
    }

    #[test]
    fn test_provider_identity_registration_canonical_does_not_escape_html() {
        let mut templates = std::collections::HashMap::new();
        templates.insert("a<&>".to_string(), "v<&>".to_string());

        let bytes = build_provider_identity_registration_canonical(
            "id<&>pk",
            Some("x25519"),
            None,
            None,
            "inprocess-mlx",
            true,
            None,
            None,
            &templates,
            None,
        )
        .expect("canonical build should succeed");

        let expected = br#"{"backend":"inprocess-mlx","domain":"darkbloom.provider.registration.v1","encrypted_response_chunks":true,"provider_identity_public_key":"id<&>pk","public_key":"x25519","template_hashes":{"a<&>":"v<&>"}}"#;
        assert_eq!(bytes, expected.to_vec());
    }

    #[test]
    fn test_provider_identity_challenge_canonical_does_not_escape_html() {
        let mut templates = std::collections::HashMap::new();
        templates.insert("a<&>".to_string(), "v<&>".to_string());

        let mut models = std::collections::HashMap::new();
        models.insert("m<&>".to_string(), "w<&>".to_string());

        let nonce = provider_identity_html_test_nonce();
        let bytes = build_provider_identity_challenge_canonical(
            "id<&>pk",
            "x<&>25519",
            &nonce,
            "2026-04-28T20:00:00Z",
            None,
            None,
            None,
            None,
            Some("bin<&>hash"),
            None,
            None,
            None,
            &templates,
            &models,
        )
        .expect("canonical build should succeed");

        let expected = format!(
            r#"{{"binary_hash":"bin<&>hash","domain":"darkbloom.provider.challenge.v1","model_hashes":{{"m<&>":"w<&>"}},"nonce":"{}","provider_identity_public_key":"id<&>pk","public_key":"x<&>25519","template_hashes":{{"a<&>":"v<&>"}},"timestamp":"2026-04-28T20:00:00Z"}}"#,
            nonce
        );
        assert_eq!(bytes, expected.into_bytes());
    }

    /// Mirror of Go's TestBuildStatusCanonicalUnicodeNonce. Both
    /// serializers must pass printable Unicode through as UTF-8 (no
    /// double-escaping). Today nonces are base64 ASCII so this is
    /// future-proofing for any signed string field that might one day
    /// carry non-ASCII.
    #[test]
    fn test_build_status_canonical_unicode_nonce() {
        let bytes = build_status_canonical(
            "ñön¢é-π",
            "t",
            None,
            None,
            None,
            None,
            None,
            None,
            None,
            None,
            &std::collections::HashMap::new(),
            None,
            None,
            &std::collections::HashMap::new(),
        )
        .expect("canonical build should succeed");
        assert_eq!(
            bytes,
            "{\"nonce\":\"ñön¢é-π\",\"timestamp\":\"t\"}"
                .as_bytes()
                .to_vec()
        );
    }

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
            None,
            None,
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
            None,
            None,
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
            None,
            None,
        );
        let resp2 = handle_attestation_challenge(
            "bm9uY2U=",
            "2025-01-15T00:00:00Z",
            Some("key"),
            None,
            None,
            std::collections::HashMap::new(),
            None,
            None,
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
            None,
            None,
        );
        let resp2 = handle_attestation_challenge(
            "bm9uY2Uy",
            "2025-01-15T00:00:00Z",
            Some("key"),
            None,
            None,
            std::collections::HashMap::new(),
            None,
            None,
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
            None,
            None,
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

        // Plaintext inference requests should be rejected before they reach the
        // main loop. The mock server immediately closes after sending cancel, so
        // either event may arrive first; the key invariant is that no
        // InferenceRequest reaches the provider event loop.
        for _ in 0..2 {
            let event = tokio::time::timeout(Duration::from_secs(5), event_rx.recv())
                .await
                .expect("timeout waiting for follow-up event")
                .expect("channel closed");
            match event {
                CoordinatorEvent::Cancel { request_id } => {
                    assert_eq!(request_id, "test-req-1");
                    break;
                }
                CoordinatorEvent::Disconnected => break,
                CoordinatorEvent::InferenceRequest { .. } => {
                    panic!("plaintext request should not reach the inference loop")
                }
                other => panic!("unexpected follow-up event: {:?}", other),
            }
        }

        // Shutdown
        let _ = shutdown_tx.send(true);
        let _ = tokio::time::timeout(Duration::from_secs(2), client_handle).await;

        // Verify server received register and inference_error messages.
        // Heartbeats may arrive between them, so search by type.
        let received = server_handle.await.unwrap();
        assert!(
            received.len() >= 2,
            "expected at least register and error messages, got {}",
            received.len()
        );
        let register: serde_json::Value = serde_json::from_str(&received[0]).unwrap();
        assert_eq!(register["type"], "register");
        assert_eq!(register["backend"], "vllm_mlx");
        let err = received
            .iter()
            .filter_map(|m| serde_json::from_str::<serde_json::Value>(m).ok())
            .find(|v| v["type"] == "inference_error")
            .expect("expected an inference_error message");
        assert_eq!(err["request_id"], "test-req-1");
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
            None,
            None,
        );

        match response {
            ProviderMessage::AttestationResponse {
                nonce,
                signature,
                status_signature: _,
                provider_identity_signature: _,
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
                model_hashes: _,
            } => {
                // Nonce echoed back exactly
                assert_eq!(nonce, "dGVzdG5vbmNl");
                // Signature: empty in test env (no Secure Enclave),
                // base64-encoded DER ECDSA in production.
                let _ = signature;
                // Public key matches input
                assert_eq!(public_key, "cHVibGljLWtleQ==");
                // Security status fields that have reliable software checks are populated.
                assert!(sip_enabled.is_some(), "sip_enabled must be present");
                assert!(rdma_disabled.is_some(), "rdma_disabled must be present");
                assert!(
                    hypervisor_active.is_some(),
                    "hypervisor_active must be present"
                );
                // Secure Boot is omitted when macOS cannot provide a non-interactive answer.
                let _ = secure_boot_enabled;
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
            None,
            None,
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
            None,
            None,
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
            None,
            None,
        );
        let resp2 = handle_attestation_challenge(
            "bm9uY2U=",
            "2026-06-01T00:00:00Z",
            Some("key"),
            None,
            None,
            std::collections::HashMap::new(),
            None,
            None,
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
            None,
            None,
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
