//! Shared harness for the provider-session integration tests: a real axum
//! server whose WebSocket route runs `provider_session::serve`, a real
//! spawned `FleetActor`, and a fake Swift-provider client speaking genuine
//! v1/v2 JSON + binary frames over tokio-tungstenite. Used by the
//! `session` suite and (for `FakeProvider`) the full-stack `e2e` suite.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use arc_swap::ArcSwap;
use axum::extract::ws::WebSocketUpgrade;
use axum::routing::any;
use axum::Router;
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use futures::{SinkExt, StreamExt};
use p256::ecdsa::signature::Signer;
use p256::ecdsa::{Signature, SigningKey};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tokio_tungstenite::{connect_async_with_config, MaybeTlsStream, WebSocketStream};

use darkbloom_core::fleet::admission::{AdmissionConfig, RequestTraits};
use darkbloom_core::ids::{CoordinatorEpoch, JobId, ModelId};
use darkbloom_core::money::Tokens;
use darkbloom_core::settlement::MicroUsdPerMTokens;
use darkbloom_protocol::crypto::nacl_box;
use darkbloom_protocol::crypto::signing::{build_status_canonical, StatusCanonicalInput};
use darkbloom_protocol::crypto::terminal_digest;
use darkbloom_protocol::json_v2::TerminalFrame;
use darkbloom_server::contracts::{
    fleet_channels, AdmitOutcome, AdmitRequest, CatalogSnapshot, CoordinatorKeys, FleetHandle,
    PriceCard,
};
use darkbloom_server::fleet::{self, FleetConfig, FleetRuntime, FleetTunables};
use darkbloom_server::provider_session::{self, NoProviderAuth, SessionConfig, SessionDeps};
use darkbloom_server::trust::TrustVerifier;

pub const MODEL: &str = "concrete-build";
pub const ALIAS: &str = "public-model";
pub const COORD_EPOCH: u64 = 7;

pub struct Harness {
    pub addr: SocketAddr,
    pub fleet: FleetHandle,
    pub runtime: FleetRuntime,
}

impl Harness {
    pub async fn start() -> Self {
        Self::start_with(SessionConfig::default(), FleetTunables::default()).await
    }

    pub async fn start_with(session_config: SessionConfig, tunables: FleetTunables) -> Self {
        let catalog = Arc::new(ArcSwap::from_pointee(CatalogSnapshot {
            version: 1,
            aliases: [(ALIAS.to_owned(), MODEL.to_owned())].into_iter().collect(),
            prices: [(
                MODEL.to_owned(),
                PriceCard {
                    prompt_micro_per_mtok: MicroUsdPerMTokens::new(3_000_000).expect("rate"),
                    completion_micro_per_mtok: MicroUsdPerMTokens::new(11_000_000).expect("rate"),
                },
            )]
            .into_iter()
            .collect(),
        }));
        let (fleet_handle, receivers) = fleet_channels(256, 256);
        let cancel = tokio_util::sync::CancellationToken::new();
        let runtime = fleet::spawn(FleetConfig {
            receivers,
            admission: AdmissionConfig::default(),
            catalog,
            cancel,
            tunables,
        });

        let (_, coordinator_secret) = nacl_box::generate_keypair();
        let deps = SessionDeps {
            fleet: fleet_handle.clone(),
            trust: Arc::new(TrustVerifier::new()),
            keys: Arc::new(CoordinatorKeys {
                x25519_public_b64: nacl_box::encode_public_key(&coordinator_secret.public_key()),
                x25519_secret: coordinator_secret,
            }),
            auth: Arc::new(NoProviderAuth),
            coordinator_epoch: CoordinatorEpoch::new(COORD_EPOCH),
            config: session_config,
        };
        let max_frame = deps.config.max_frame_bytes;
        let app = Router::new().route(
            "/v1/providers/connect",
            any(move |upgrade: WebSocketUpgrade| {
                let deps = deps.clone();
                async move {
                    upgrade
                        .max_message_size(max_frame)
                        .on_upgrade(move |socket| provider_session::serve(socket, deps))
                }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind test listener");
        let addr = listener.local_addr().expect("listener addr");
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        Self {
            addr,
            fleet: fleet_handle,
            runtime,
        }
    }

    /// Polls admission until it grants (heartbeats/lifecycle reduce
    /// asynchronously) or the deadline passes.
    pub async fn admit_until_grant(
        &self,
        model: &str,
    ) -> Box<darkbloom_server::contracts::AdmitGrant> {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        loop {
            match self.admit_once(model).await {
                AdmitOutcome::Grant(grant) => return grant,
                other => {
                    assert!(
                        tokio::time::Instant::now() < deadline,
                        "admission never granted: last outcome {}",
                        outcome_kind(&other),
                    );
                    tokio::time::sleep(Duration::from_millis(25)).await;
                }
            }
        }
    }

    pub async fn admit_once(&self, model: &str) -> AdmitOutcome {
        self.fleet
            .admit(admit_request(model))
            .await
            .expect("fleet reachable")
    }
}

pub fn outcome_kind(outcome: &AdmitOutcome) -> String {
    match outcome {
        AdmitOutcome::Grant(_) => "grant".to_owned(),
        AdmitOutcome::RetryAfter { reason, .. } => format!("retry_after:{reason}"),
        AdmitOutcome::Reject(reason) => format!("reject:{reason:?}"),
    }
}

pub fn admit_request(model: &str) -> AdmitRequest {
    AdmitRequest {
        job: JobId::new(uuid::Uuid::new_v4()),
        model: ModelId::new(model),
        traits: RequestTraits {
            model: ModelId::new(model),
            needs_vision: false,
            needs_tools: false,
            needs_media: false,
            paid: false,
            expected_output_tokens: Tokens::new(100),
        },
        estimated_prompt_tokens: 64,
        requested_max_tokens: 256,
        exclude: Vec::new(),
        paid: false,
    }
}

/// A fake Swift provider with real key material: a P-256 "Secure Enclave"
/// signing key and an X25519 transport key.
pub struct FakeProvider {
    pub ws: WebSocketStream<MaybeTlsStream<TcpStream>>,
    pub se_key: SigningKey,
    pub se_pub_b64: String,
    pub x25519_secret: nacl_box::SecretKey,
    pub x25519_pub_b64: String,
    pub serial: String,
    /// Concrete model id declared in the register frame.
    pub model: String,
    /// Registration auth token (earnings account link); empty = none.
    pub auth_token: String,
}

impl FakeProvider {
    pub async fn connect(harness: &Harness, serial: &str) -> Self {
        Self::connect_keyed(harness.addr, serial, [0x21; 32], [0x31; 32]).await
    }

    /// Connects to any coordinator address (the full-stack tests boot the
    /// real bootstrap app instead of this module's session-only harness).
    pub async fn connect_addr(addr: SocketAddr, serial: &str) -> Self {
        Self::connect_keyed(addr, serial, [0x21; 32], [0x31; 32]).await
    }

    /// Deterministic keys so a "reconnect" carries the same stable identity.
    pub async fn connect_keyed(
        addr: SocketAddr,
        serial: &str,
        se_seed: [u8; 32],
        x_seed: [u8; 32],
    ) -> Self {
        let url = format!("ws://{addr}/v1/providers/connect");
        let config = WebSocketConfig {
            max_message_size: Some(64 * 1024 * 1024),
            max_frame_size: Some(64 * 1024 * 1024),
            ..Default::default()
        };
        let (ws, _) = connect_async_with_config(url, Some(config), false)
            .await
            .expect("provider websocket connect");
        let se_key = SigningKey::from_slice(&se_seed).expect("valid P-256 scalar");
        let se_pub_b64 = BASE64.encode(se_key.verifying_key().to_encoded_point(false).as_bytes());
        let x25519_secret = nacl_box::SecretKey::from(x_seed);
        let x25519_pub_b64 = nacl_box::encode_public_key(&x25519_secret.public_key());
        Self {
            ws,
            se_key,
            se_pub_b64,
            x25519_secret,
            x25519_pub_b64,
            serial: serial.to_owned(),
            model: MODEL.to_owned(),
            auth_token: String::new(),
        }
    }

    fn sign_b64(&self, payload: &[u8]) -> String {
        let sig: Signature = self.se_key.sign(payload);
        BASE64.encode(sig.to_der().as_bytes())
    }

    /// Fills `se_signature` with a REAL signature over the canonical
    /// terminal bytes, exactly as the Swift provider's Secure Enclave does
    /// — the coordinator session verifies it before intake (plan §12.6).
    pub fn sign_terminal(&self, mut frame: TerminalFrame) -> TerminalFrame {
        frame.se_signature =
            terminal_digest::sign_terminal(&self.se_key, &frame).expect("sign terminal");
        frame
    }

    /// Signed attestation blob exactly as embedded (signature covers these
    /// raw bytes — the register frame must carry them unmodified).
    fn signed_attestation(&self) -> String {
        let blob = format!(
            concat!(
                r#"{{"encryptionPublicKey":"{x}","publicKey":"{p}","#,
                r#""secureBootEnabled":true,"secureEnclaveAvailable":true,"#,
                r#""serialNumber":"{s}","sipEnabled":true,"#,
                r#""timestamp":"2026-07-09T00:00:00Z"}}"#
            ),
            x = self.x25519_pub_b64,
            p = self.se_pub_b64,
            s = self.serial,
        );
        let signature = self.sign_b64(blob.as_bytes());
        format!(r#"{{"attestation":{blob},"signature":"{signature}"}}"#)
    }

    /// Sends the v1 register frame; `v2` adds the protocol_v2 extension.
    /// The declared model is `self.model`; a non-empty `self.auth_token`
    /// rides as the earnings-account link.
    pub async fn register(&mut self, v2: bool) {
        let attestation = self.signed_attestation();
        let extension = if v2 {
            concat!(
                r#","protocol_v2":{"protocol_major":2,"protocol_minor":0,"#,
                r#""capabilities":["prepared_lease","start_ack","abort_ack","cancel_ack","#,
                r#""structured_errors","durable_terminals","model_lifecycle","binary_frames"],"#,
                r#""process_generation":1}"#
            )
        } else {
            ""
        };
        let auth = if self.auth_token.is_empty() {
            String::new()
        } else {
            format!(r#","auth_token":"{}""#, self.auth_token)
        };
        let frame = format!(
            concat!(
                r#"{{"type":"register","#,
                r#""hardware":{{"machine_model":"Mac16,1","chip_name":"Apple M4 Max","#,
                r#""chip_family":"M4","chip_tier":"Max","memory_gb":64,"#,
                r#""memory_available_gb":48.0,"cpu_cores":{{"total":16,"performance":12,"efficiency":4}},"#,
                r#""gpu_cores":40,"memory_bandwidth_gbs":546.0}},"#,
                r#""models":[{{"id":"{model}","size_bytes":123,"model_type":"mlx","quantization":"4bit"}}],"#,
                r#""backend":"mlx-swift","version":"0.8.0","public_key":"{x}","#,
                r#""encrypted_response_chunks":true{auth},"attestation":{attestation}{extension}}}"#
            ),
            model = self.model,
            x = self.x25519_pub_b64,
            auth = auth,
            attestation = attestation,
            extension = extension,
        );
        self.ws
            .send(WsMessage::Text(frame))
            .await
            .expect("send register");
    }

    /// Reads the immediate attestation challenge and answers it with real
    /// signatures (nonce+timestamp plus canonical status).
    pub async fn answer_challenge(&mut self) {
        let challenge = self.next_json().await;
        assert_eq!(challenge["type"], "attestation_challenge");
        let nonce = challenge["nonce"].as_str().expect("nonce").to_owned();
        let timestamp = challenge["timestamp"]
            .as_str()
            .expect("timestamp")
            .to_owned();

        let signature = self.sign_b64(format!("{nonce}{timestamp}").as_bytes());
        let status_input = StatusCanonicalInput {
            nonce: nonce.clone(),
            timestamp: timestamp.clone(),
            rdma_disabled: Some(true),
            sip_enabled: Some(true),
            secure_boot_enabled: Some(true),
            ..Default::default()
        };
        let status_signature = self.sign_b64(&build_status_canonical(&status_input));
        let response = serde_json::json!({
            "type": "attestation_response",
            "nonce": nonce,
            "signature": signature,
            "status_signature": status_signature,
            "public_key": self.x25519_pub_b64,
            "rdma_disabled": true,
            "sip_enabled": true,
            "secure_boot_enabled": true,
        });
        self.send_json(&response).await;
    }

    /// v1 heartbeat with one authoritative backend slot for `model`.
    pub async fn send_heartbeat(&mut self, model: &str, state: &str) {
        let heartbeat = serde_json::json!({
            "type": "heartbeat",
            "status": "idle",
            "active_model": model,
            "stats": {"requests_served": 1, "tokens_generated": 10},
            "system_metrics": {"memory_pressure": 0.2, "cpu_usage": 0.1, "thermal_state": "nominal"},
            "backend_capacity": {
                "slots": [{
                    "model": model,
                    "state": state,
                    "num_running": 0,
                    "num_waiting": 0,
                    "max_concurrency": 4,
                    "active_tokens": 0,
                    "max_tokens_potential": 8192,
                    "observed_decode_tps": 42.0,
                }],
                "gpu_memory_active_gb": 8.0,
                "gpu_memory_peak_gb": 9.0,
                "gpu_memory_cache_gb": 1.0,
                "total_memory_gb": 64.0,
            },
        });
        self.send_json(&heartbeat).await;
    }

    pub async fn send_json(&mut self, value: &serde_json::Value) {
        self.ws
            .send(WsMessage::Text(value.to_string()))
            .await
            .expect("send json frame");
    }

    pub async fn send_binary(&mut self, bytes: Vec<u8>) {
        self.ws
            .send(WsMessage::Binary(bytes))
            .await
            .expect("send binary frame");
    }

    /// Next text frame as JSON, skipping transport noise.
    pub async fn next_json(&mut self) -> serde_json::Value {
        let text = self.next_text().await;
        serde_json::from_str(&text).expect("frame is JSON")
    }

    pub async fn next_text(&mut self) -> String {
        loop {
            match self.next_message().await {
                WsMessage::Text(text) => return text.to_string(),
                WsMessage::Binary(_) => panic!("unexpected binary frame"),
                _ => continue,
            }
        }
    }

    pub async fn next_binary(&mut self) -> Vec<u8> {
        loop {
            match self.next_message().await {
                WsMessage::Binary(bytes) => return bytes.to_vec(),
                WsMessage::Text(text) => panic!("unexpected text frame: {text}"),
                _ => continue,
            }
        }
    }

    pub async fn next_message(&mut self) -> WsMessage {
        loop {
            let frame = tokio::time::timeout(Duration::from_secs(10), self.ws.next())
                .await
                .expect("frame within deadline")
                .expect("socket open")
                .expect("read ok");
            match frame {
                WsMessage::Ping(_) | WsMessage::Pong(_) => continue,
                other => return other,
            }
        }
    }

    /// Standard session bring-up: register, answer the initial challenge.
    pub async fn establish(&mut self, v2: bool) {
        self.register(v2).await;
        self.answer_challenge().await;
    }
}

/// Fresh per-attempt sinks: a bounded event channel plus a byte-bounded
/// chunk pipe.
pub fn attempt_sinks() -> (
    darkbloom_server::contracts::AttemptSinks,
    tokio::sync::mpsc::Receiver<darkbloom_server::contracts::AttemptEvent>,
    darkbloom_server::contracts::ChunkReceiver,
) {
    let (event_tx, event_rx) = tokio::sync::mpsc::channel(32);
    let (chunk_tx, chunk_rx) = darkbloom_server::contracts::chunk_pipe(64, 1 << 20);
    (
        darkbloom_server::contracts::AttemptSinks {
            events: event_tx,
            chunks: chunk_tx,
        },
        event_rx,
        chunk_rx,
    )
}
