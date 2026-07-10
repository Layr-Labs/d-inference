//! Shared integration-test harness: fakes for every frozen seam
//! (`contracts.rs`) — an in-memory recording ledger, a static API-key
//! store, a scripted fleet actor, and provider simulators that drain real
//! session channels. No real database, no real fleet, no real sockets.
//!
//! Included from `http_*.rs` / `request_*.rs` test crates via
//! `#[path = "http_harness.rs"] mod harness;`.

#![allow(dead_code)]

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use arc_swap::ArcSwap;
use axum::Router;
use bytes::Bytes;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use darkbloom_core::fleet::admission::AdmissionConfig;
use darkbloom_core::ids::{
    AccountId, ApiKeyId, CoordinatorEpoch, JobId, PermitId, ProviderId, SessionEpoch,
};
use darkbloom_core::money::MicroUsd;
use darkbloom_core::settlement::MicroUsdPerMTokens;
use darkbloom_core::time::{DurationMs, TimestampMs};
use darkbloom_protocol::crypto::nacl_box::{self, PublicKey, SecretKey, NONCE_LEN};

use darkbloom_server::contracts::{
    fleet_channels, session_channels, AdmitGrant, AdmitOutcome, AdmitRequest, ApiKeyRecord,
    ApiKeyStore, AppState, CatalogSnapshot, ControlFrame, CoordinatorKeys, DataFrame, FleetCommand,
    FleetObservation, LedgerError, LedgerFacade, PriceCard, ProtocolGen, ReleaseParams,
    RequestPolicy, ReserveOutcome, ReserveParams, ResizeFreezeParams, SessionCommand,
    SessionHandle, SessionLaneCaps, SessionReceivers, SettleOutcome, SettleParams,
};
use darkbloom_server::http::{build_router_with, HttpConfig};
use darkbloom_server::request_task::{shared_hedge_budget, RequestTaskDeps};

pub const RECV_TIMEOUT: Duration = Duration::from_secs(5);

pub const PUBLIC_MODEL: &str = "gemma-4";
pub const CONCRETE_MODEL: &str = "gemma-4-26b-4bit";
pub const API_TOKEN: &str = "sk-test-token";

// ---------------------------------------------------------------------
// Fake ledger
// ---------------------------------------------------------------------

#[derive(Debug, Clone)]
pub enum LedgerCall {
    Reserve(ReserveParams),
    Resize(ResizeFreezeParams),
    MarkRunning(JobId),
    Settle(SettleParams),
    Release(ReleaseParams),
    Review(JobId, String),
}

#[derive(Default)]
pub struct FakeLedger {
    pub calls: Mutex<Vec<LedgerCall>>,
    /// When set, `reserve` fails with this error once.
    pub reserve_error: Mutex<Option<LedgerError>>,
}

impl FakeLedger {
    pub fn snapshot(&self) -> Vec<LedgerCall> {
        self.calls.lock().unwrap().clone()
    }

    pub fn count(&self, name: &str) -> usize {
        self.snapshot()
            .iter()
            .filter(|c| call_name(c) == name)
            .count()
    }

    pub fn find_settle(&self) -> Option<SettleParams> {
        self.snapshot().into_iter().find_map(|c| match c {
            LedgerCall::Settle(p) => Some(p),
            _ => None,
        })
    }

    pub fn find_resize(&self) -> Option<ResizeFreezeParams> {
        self.snapshot().into_iter().find_map(|c| match c {
            LedgerCall::Resize(p) => Some(p),
            _ => None,
        })
    }
}

pub fn call_name(call: &LedgerCall) -> &'static str {
    match call {
        LedgerCall::Reserve(_) => "reserve",
        LedgerCall::Resize(_) => "resize",
        LedgerCall::MarkRunning(_) => "mark_running",
        LedgerCall::Settle(_) => "settle",
        LedgerCall::Release(_) => "release",
        LedgerCall::Review(_, _) => "review",
    }
}

#[async_trait::async_trait]
impl LedgerFacade for FakeLedger {
    async fn reserve(&self, p: ReserveParams) -> Result<ReserveOutcome, LedgerError> {
        if let Some(err) = self.reserve_error.lock().unwrap().take() {
            return Err(err);
        }
        let hold = p.hold;
        self.calls.lock().unwrap().push(LedgerCall::Reserve(p));
        Ok(ReserveOutcome {
            reserved_total: hold,
            reserved_withdrawable: MicroUsd::ZERO,
        })
    }

    async fn resize_freeze(&self, p: ResizeFreezeParams) -> Result<(), LedgerError> {
        self.calls.lock().unwrap().push(LedgerCall::Resize(p));
        Ok(())
    }

    async fn mark_running(&self, job: JobId) -> Result<(), LedgerError> {
        self.calls
            .lock()
            .unwrap()
            .push(LedgerCall::MarkRunning(job));
        Ok(())
    }

    async fn settle(&self, p: SettleParams) -> Result<SettleOutcome, LedgerError> {
        self.calls.lock().unwrap().push(LedgerCall::Settle(p));
        Ok(SettleOutcome {
            charged: MicroUsd::new(1),
            refunded: MicroUsd::ZERO,
            provider_payout: MicroUsd::ZERO,
            flagged_for_review: false,
        })
    }

    async fn release(&self, p: ReleaseParams) -> Result<(), LedgerError> {
        self.calls.lock().unwrap().push(LedgerCall::Release(p));
        Ok(())
    }

    async fn move_to_review(&self, job: JobId, reason: String) -> Result<(), LedgerError> {
        self.calls
            .lock()
            .unwrap()
            .push(LedgerCall::Review(job, reason));
        Ok(())
    }
}

// ---------------------------------------------------------------------
// Fake API keys
// ---------------------------------------------------------------------

pub struct FakeKeys {
    pub records: HashMap<String, ApiKeyRecord>,
}

impl FakeKeys {
    pub fn single(account: AccountId) -> Self {
        let mut records = HashMap::new();
        records.insert(
            API_TOKEN.to_owned(),
            ApiKeyRecord {
                key_id: ApiKeyId::new("key-test"),
                account,
                spend_cap: None,
                disabled: false,
            },
        );
        Self { records }
    }
}

#[async_trait::async_trait]
impl ApiKeyStore for FakeKeys {
    async fn validate(&self, token: &str) -> Option<ApiKeyRecord> {
        self.records.get(token).cloned()
    }
}

// ---------------------------------------------------------------------
// Provider simulator (plays the provider_session + provider)
// ---------------------------------------------------------------------

pub struct ProviderSim {
    pub provider: ProviderId,
    pub protocol: ProtocolGen,
    pub secret: SecretKey,
    pub public_b64: String,
    pub handle: SessionHandle,
    pub receivers: SessionReceivers,
}

/// One attached attempt as seen by the session: the request task's sinks.
pub struct AttachedAttempt {
    pub wire_id: String,
    pub attempt: darkbloom_core::ids::AttemptId,
    pub events: mpsc::Sender<darkbloom_server::contracts::AttemptEvent>,
    pub chunks: darkbloom_server::contracts::ChunkSender,
}

impl ProviderSim {
    pub fn new(protocol: ProtocolGen) -> Self {
        let provider = ProviderId::new(Uuid::new_v4());
        let (public, secret) = nacl_box::generate_keypair();
        let (handle, receivers) = session_channels(
            provider,
            SessionEpoch::new(1),
            protocol,
            SessionLaneCaps::default(),
        );
        Self {
            provider,
            protocol,
            secret,
            public_b64: nacl_box::encode_public_key(&public),
            handle,
            receivers,
        }
    }

    pub async fn expect_attach(&mut self) -> AttachedAttempt {
        let command = tokio::time::timeout(RECV_TIMEOUT, self.receivers.command_rx.recv())
            .await
            .expect("timed out waiting for attach")
            .expect("command lane closed");
        match command {
            SessionCommand::AttachAttempt {
                wire_id,
                attempt,
                sinks,
            } => AttachedAttempt {
                wire_id,
                attempt,
                events: sinks.0.events,
                chunks: sinks.0.chunks,
            },
            SessionCommand::DetachAttempt { wire_id } => {
                panic!("expected attach, got detach for {wire_id}")
            }
        }
    }

    /// Next data-lane frame, acknowledging the on-wire completion.
    pub async fn expect_data(&mut self) -> DataFrame {
        let (frame, tx) = tokio::time::timeout(RECV_TIMEOUT, self.receivers.data_rx.recv())
            .await
            .expect("timed out waiting for data frame")
            .expect("data lane closed");
        let _ = tx.send(Ok(()));
        frame
    }

    /// Next control-lane frame, acknowledging the on-wire completion.
    pub async fn expect_control(&mut self) -> ControlFrame {
        let (frame, tx) = tokio::time::timeout(RECV_TIMEOUT, self.receivers.control_rx.recv())
            .await
            .expect("timed out waiting for control frame")
            .expect("control lane closed");
        let _ = tx.send(Ok(()));
        frame
    }

    /// Seals a v2 chunk exactly like a provider: to the coordinator's
    /// long-lived key with the provider's registered key. Returns the raw
    /// `nonce || box` relay bytes the session would forward.
    pub fn seal_v2_chunk(&self, coordinator_public: &PublicKey, plaintext: &[u8]) -> Bytes {
        let mut nonce = [0u8; NONCE_LEN];
        rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut nonce);
        Bytes::from(
            nacl_box::seal_bytes(plaintext, &nonce, coordinator_public, &self.secret)
                .expect("seal chunk"),
        )
    }

    /// Seals a v1 chunk: to the per-request session key (the
    /// `ephemeral_public_key` from the request envelope) with the
    /// provider's registered key.
    pub fn seal_v1_chunk(&self, session_public_b64: &str, plaintext: &[u8]) -> Bytes {
        let session_public =
            nacl_box::parse_public_key(session_public_b64).expect("session public key");
        let mut nonce = [0u8; NONCE_LEN];
        rand::RngCore::fill_bytes(&mut rand::rngs::OsRng, &mut nonce);
        Bytes::from(
            nacl_box::seal_bytes(plaintext, &nonce, &session_public, &self.secret)
                .expect("seal chunk"),
        )
    }
}

// ---------------------------------------------------------------------
// Scripted fleet actor
// ---------------------------------------------------------------------

/// One scripted reply per `FleetCommand::Admit`, in order.
pub enum AdmitReply {
    /// Grant the provider at this index of the harness provider list.
    Grant(usize),
    RetryAfter(Duration),
    Reject,
}

#[derive(Default)]
pub struct FleetRecord {
    pub admits: Mutex<Vec<AdmitRequest>>,
    /// (provider, permit) minted per grant, in grant order.
    pub minted: Mutex<Vec<(ProviderId, PermitId)>>,
    pub releases: Mutex<Vec<(ProviderId, PermitId)>>,
    pub observations: Mutex<Vec<String>>,
}

impl FleetRecord {
    pub fn admit_count(&self) -> usize {
        self.admits.lock().unwrap().len()
    }

    /// Every released permit id was minted for the same provider — the
    /// permit-identity echo invariant.
    pub fn assert_releases_echo_minted(&self) {
        let minted = self.minted.lock().unwrap().clone();
        for (provider, permit) in self.releases.lock().unwrap().iter() {
            assert!(
                minted.iter().any(|(p, id)| p == provider && id == permit),
                "released permit {permit} was never minted for provider {provider}"
            );
        }
    }
}

// ---------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------

pub struct Harness {
    pub router: Router,
    pub state: AppState,
    pub task_deps: RequestTaskDeps,
    pub ledger: Arc<FakeLedger>,
    pub fleet_record: Arc<FleetRecord>,
    pub providers: Vec<ProviderSim>,
    pub account: AccountId,
    pub coordinator_public: PublicKey,
    pub shutdown: CancellationToken,
    /// The requests-phase tracker every chat-spawned request task joins
    /// (plan §15.1 step 2) — tests drain it like the supervisor would.
    pub request_tracker: tokio_util::task::TaskTracker,
}

/// 2 µUSD per prompt token / 5 µUSD per completion token, expressed as the
/// exact per-MTok rates the contract carries.
pub fn price_card() -> PriceCard {
    PriceCard {
        prompt_micro_per_mtok: MicroUsdPerMTokens::new(2_000_000).expect("rate"),
        completion_micro_per_mtok: MicroUsdPerMTokens::new(5_000_000).expect("rate"),
    }
}

pub fn default_policy() -> RequestPolicy {
    RequestPolicy {
        first_content_base: Duration::from_secs(10),
        first_content_per_prompt_token: Duration::from_millis(1),
        request_deadline: Duration::from_secs(60),
        hedge_enabled: true,
        hedge_budget_fraction: 0.05,
        hedge_prepare_timeout: Duration::from_secs(5),
        prepare_deadline: Duration::from_secs(5),
        terminal_wait: Duration::from_millis(400),
        pipe_max_items: 64,
        pipe_max_bytes: 256 * 1024,
        stream_idle_timeout: Duration::from_secs(10),
        provider_payout_ppm: 800_000,
    }
}

pub struct HarnessBuilder {
    policy: RequestPolicy,
    protocols: Vec<ProtocolGen>,
    script: Vec<AdmitReply>,
    reserve_error: Option<LedgerError>,
}

impl Default for HarnessBuilder {
    fn default() -> Self {
        Self::new()
    }
}

impl HarnessBuilder {
    pub fn new() -> Self {
        Self {
            policy: default_policy(),
            protocols: vec![ProtocolGen::V2],
            script: vec![AdmitReply::Grant(0)],
            reserve_error: None,
        }
    }

    pub fn policy(mut self, f: impl FnOnce(&mut RequestPolicy)) -> Self {
        f(&mut self.policy);
        self
    }

    pub fn providers(mut self, protocols: Vec<ProtocolGen>) -> Self {
        self.protocols = protocols;
        self
    }

    pub fn admit_script(mut self, script: Vec<AdmitReply>) -> Self {
        self.script = script;
        self
    }

    pub fn reserve_error(mut self, err: LedgerError) -> Self {
        self.reserve_error = Some(err);
        self
    }

    pub fn build(self) -> Harness {
        let account = AccountId::new(Uuid::new_v4());
        let ledger = Arc::new(FakeLedger::default());
        *ledger.reserve_error.lock().unwrap() = self.reserve_error;

        let providers: Vec<ProviderSim> = self
            .protocols
            .iter()
            .map(|p| ProviderSim::new(*p))
            .collect();
        let mut grant_info = Vec::new();
        for sim in &providers {
            grant_info.push((sim.provider, sim.handle.clone(), sim.public_b64.clone()));
        }

        let (fleet, mut fleet_rx) = fleet_channels(64, 64);
        let fleet_record = Arc::new(FleetRecord::default());
        let record = fleet_record.clone();
        let mut script: VecDeque<AdmitReply> = self.script.into();
        let price = price_card();
        let beneficiary = AccountId::new(Uuid::new_v4());
        tokio::spawn(async move {
            while let Some(command) = fleet_rx.commands.recv().await {
                match command {
                    FleetCommand::Admit { req, reply } => {
                        record.admits.lock().unwrap().push(req.clone());
                        let outcome = match script.pop_front() {
                            Some(AdmitReply::Grant(index)) => {
                                let (provider, session, key_b64) = grant_info[index].clone();
                                // Minted per grant like the real fleet; the
                                // request task must ECHO it on release.
                                let permit_id = PermitId::new(Uuid::new_v4());
                                record.minted.lock().unwrap().push((provider, permit_id));
                                AdmitOutcome::Grant(Box::new(AdmitGrant {
                                    permit: darkbloom_core::fleet::admission::DispatchPermit {
                                        provider,
                                        model: darkbloom_core::ids::ModelId::new(CONCRETE_MODEL),
                                        expires_at: TimestampMs::new(i64::MAX / 2),
                                        permit_ttl: DurationMs::new(10_000),
                                        is_probe: false,
                                        predicted_first_content: DurationMs::new(50),
                                    },
                                    permit_id,
                                    provider,
                                    session,
                                    provider_public_key_b64: key_b64,
                                    concrete_model: darkbloom_core::ids::ModelId::new(
                                        CONCRETE_MODEL,
                                    ),
                                    price,
                                    beneficiary: Some(beneficiary),
                                    predicted_first_content: Duration::from_millis(50),
                                }))
                            }
                            Some(AdmitReply::RetryAfter(delay)) => AdmitOutcome::RetryAfter {
                                reason: "saturated".to_owned(),
                                delay,
                            },
                            Some(AdmitReply::Reject) | None => AdmitOutcome::Reject(
                                darkbloom_core::fleet::admission::RejectionReason::NoCandidates,
                            ),
                        };
                        let _ = reply.send(outcome);
                    }
                    FleetCommand::ReleasePermit { provider, permit } => {
                        record.releases.lock().unwrap().push((provider, permit));
                    }
                    FleetCommand::Observe(obs) => {
                        record.observations.lock().unwrap().push(observe_name(&obs));
                    }
                    _ => {}
                }
            }
        });

        let (coordinator_public, coordinator_secret) = nacl_box::generate_keypair();
        let encryption = Arc::new(CoordinatorKeys {
            x25519_public_b64: nacl_box::encode_public_key(&coordinator_public),
            x25519_secret: coordinator_secret,
        });

        let mut aliases = HashMap::new();
        aliases.insert(PUBLIC_MODEL.to_owned(), CONCRETE_MODEL.to_owned());
        let mut prices = HashMap::new();
        prices.insert(CONCRETE_MODEL.to_owned(), price);
        let catalog = Arc::new(ArcSwap::from_pointee(CatalogSnapshot {
            version: 3,
            aliases,
            prices,
        }));

        let state = AppState {
            fleet,
            ledger: ledger.clone(),
            keys: Arc::new(FakeKeys::single(account)),
            catalog,
            policy: Arc::new(self.policy),
            coordinator_epoch: CoordinatorEpoch::new(7),
            encryption,
            admission_config: Arc::new(AdmissionConfig::default()),
        };

        let shutdown = CancellationToken::new();
        let request_tracker = tokio_util::task::TaskTracker::new();
        let task_deps = RequestTaskDeps::from_state(
            &state,
            shared_hedge_budget(&state.policy),
            shutdown.clone(),
        );
        let router = build_router_with(
            state.clone(),
            HttpConfig {
                global_concurrency: 64,
                per_account_concurrency: 16,
                shutdown: shutdown.clone(),
                request_tracker: request_tracker.clone(),
                ..Default::default()
            },
        );
        Harness {
            router,
            state,
            task_deps,
            ledger,
            fleet_record,
            providers,
            account,
            coordinator_public,
            shutdown,
            request_tracker,
        }
    }
}

fn observe_name(obs: &FleetObservation) -> String {
    match obs {
        FleetObservation::PrepareRejected { .. } => "prepare_rejected".to_owned(),
        FleetObservation::ProviderFault { .. } => "provider_fault".to_owned(),
        FleetObservation::FirstContent { .. } => "first_content".to_owned(),
        FleetObservation::SecurityFence { .. } => "security_fence".to_owned(),
    }
}

// ---------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------

pub fn chat_body(stream: bool) -> serde_json::Value {
    serde_json::json!({
        "model": PUBLIC_MODEL,
        "messages": [{"role": "user", "content": "say hello to the world"}],
        "stream": stream,
        "max_tokens": 64,
    })
}

pub fn chat_request(body: &serde_json::Value) -> axum::http::Request<axum::body::Body> {
    axum::http::Request::builder()
        .method("POST")
        .uri("/v1/chat/completions")
        .header("authorization", format!("Bearer {API_TOKEN}"))
        .header("content-type", "application/json")
        .body(axum::body::Body::from(serde_json::to_vec(body).unwrap()))
        .unwrap()
}

/// Collects the full response body (non-streaming or already-terminated
/// streams).
pub async fn read_body(response: axum::response::Response) -> Bytes {
    use futures::StreamExt;
    let mut stream = response.into_body().into_data_stream();
    let mut out = Vec::new();
    while let Some(frame) = tokio::time::timeout(RECV_TIMEOUT, stream.next())
        .await
        .expect("timed out reading body")
    {
        out.extend_from_slice(&frame.expect("body error"));
    }
    Bytes::from(out)
}

/// Splits a full SSE body into its event payloads (framed
/// `data: <payload>\n\n`).
pub fn sse_events(body: &[u8]) -> Vec<String> {
    let text = std::str::from_utf8(body).expect("utf8 body");
    text.split("\n\n")
        .filter(|part| !part.is_empty())
        .map(|part| part.strip_prefix("data: ").unwrap_or(part).to_owned())
        .collect()
}

/// Standard content chunk plaintext as a v1/v2 provider would emit it.
pub fn content_chunk(text: &str) -> String {
    format!(
        r#"{{"id":"chatcmpl-p","object":"chat.completion.chunk","model":"{CONCRETE_MODEL}","choices":[{{"delta":{{"content":"{text}"}},"finish_reason":null}}]}}"#
    )
}

pub fn role_preamble_chunk() -> String {
    format!(
        r#"{{"id":"chatcmpl-p","object":"chat.completion.chunk","model":"{CONCRETE_MODEL}","choices":[{{"delta":{{"role":"assistant"}},"finish_reason":null}}]}}"#
    )
}
