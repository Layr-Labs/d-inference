//! FROZEN inter-component contracts for parallel server development.
//!
//! This module defines every seam between the concurrently developed server
//! components (plan §7): the fleet mailbox, the provider-session handle and
//! writer lanes, the per-attempt event sinks, the bounded consumer byte pipe,
//! the ledger facade, and the shared application state. Component agents must
//! NOT edit this file; needed extensions live in the owning component's module
//! and are reported back for integration.
//!
//! Entry-point conventions (implemented by the owning modules):
//!
//! - `fleet::spawn(FleetConfig) -> FleetRuntime` — consumes the receivers
//!   created by [`fleet_channels`], returns join handles.
//! - `http::build_router(AppState) -> axum::Router` — all consumer routes.
//! - `provider_session::serve(socket, SessionDeps)` — one connection.
//! - `request_task::run(RequestTaskDeps, NormalizedRequest)` — one request.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use arc_swap::ArcSwap;
use bytes::Bytes;
use tokio::sync::{mpsc, oneshot};

use darkbloom_core::fleet::admission::{
    AdmissionConfig, CandidateSnapshot, DispatchPermit, RejectionReason, RequestTraits,
};
use darkbloom_core::ids::{
    AccountId, ApiKeyId, AttemptId, CoordinatorEpoch, JobId, LeaseId, ModelId, PermitId,
    ProviderId, SessionEpoch, StateRevision, TrustEpoch,
};
use darkbloom_core::money::MicroUsd;
use darkbloom_core::settlement::FrozenTerms;
use darkbloom_protocol::json_v1;
use darkbloom_protocol::json_v2;

// ---------------------------------------------------------------------------
// Shared policy and catalog snapshots (plan §8: atomically swapped)
// ---------------------------------------------------------------------------

/// Versioned request policy read by HTTP, request tasks, and the fleet actor.
#[derive(Debug, Clone)]
pub struct RequestPolicy {
    /// First-content deadline: base + per-estimated-prompt-token (plan §16).
    pub first_content_base: Duration,
    pub first_content_per_prompt_token: Duration,
    /// Absolute request deadline created at ingress (plan §16).
    pub request_deadline: Duration,
    /// Prepare-stage hedge (plan §11.8).
    pub hedge_enabled: bool,
    /// Fraction of admissions allowed to hedge (must be < 0.10).
    pub hedge_budget_fraction: f64,
    /// Primary-prepare latency timer that triggers the hedge.
    pub hedge_prepare_timeout: Duration,
    /// Hard timeout for a prepare reply before the attempt is failed.
    pub prepare_deadline: Duration,
    /// Bounded wait for a terminal after cancellation (plan §13.5).
    pub terminal_wait: Duration,
    /// Consumer chunk pipe: the grace window in bytes/items (plan §13.6).
    pub pipe_max_items: usize,
    pub pipe_max_bytes: usize,
    /// Idle timeout between streamed chunks.
    pub stream_idle_timeout: Duration,
}

/// One model's public pricing card (micro-USD per token).
#[derive(Debug, Clone, Copy)]
pub struct PriceCard {
    pub prompt_micro_per_token: MicroUsd,
    pub completion_micro_per_token: MicroUsd,
}

/// Immutable catalog snapshot (plan §8): public model -> concrete build,
/// pricing, and capability floors. Swapped atomically, never mutated.
#[derive(Debug, Clone, Default)]
pub struct CatalogSnapshot {
    pub version: u64,
    /// public/alias model id -> concrete build id.
    pub aliases: std::collections::HashMap<String, String>,
    /// concrete build id -> price card.
    pub prices: std::collections::HashMap<String, PriceCard>,
}

pub type SharedCatalog = Arc<ArcSwap<CatalogSnapshot>>;

// ---------------------------------------------------------------------------
// Provider session seam (plan §7.4, §15.2)
// ---------------------------------------------------------------------------

/// Protocol generation negotiated at registration.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProtocolGen {
    V1,
    V2,
}

/// Result of a writer-lane submission: resolved when the frame is on the wire
/// (plan §15.2: `WriteText` blocks to wire completion).
pub type OnWire = oneshot::Receiver<Result<(), WriteError>>;

#[derive(Debug, Clone, thiserror::Error)]
pub enum WriteError {
    #[error("session closed before write")]
    SessionClosed,
    #[error("write failed with ambiguous delivery")]
    Ambiguous,
}

/// Control-lane frames (small, strict priority — plan §15.2).
#[derive(Debug)]
pub enum ControlFrame {
    V1Cancel {
        request_id: String,
    },
    V2(Box<json_v2::FrameV2>),
    /// Raw pre-encoded JSON (challenges, trust status).
    RawJson(Bytes),
}

/// Data-lane frames (large inference payloads).
#[derive(Debug)]
pub enum DataFrame {
    /// v1 inference_request, pre-encoded (body already encrypted).
    V1InferenceRequest(Bytes),
    /// v2 prepare envelope: JSON control part plus binary body frame.
    V2Prepare {
        frame: Box<json_v2::FrameV2>,
        binary_body: Option<Bytes>,
    },
    RawJson(Bytes),
}

/// Events delivered to a request task's control sink (chunks bypass this and
/// go straight to the [`ChunkSender`] — plan §7.2).
#[derive(Debug)]
pub enum AttemptEvent {
    // --- v2 ---
    Prepared {
        lease: LeaseId,
        ttl: Duration,
        billable_prompt_tokens: u64,
        queue_depth: u32,
        prefill_can_start: bool,
        frame: Box<json_v2::PreparedFrame>,
    },
    Started,
    Aborted {
        reason: json_v2::AbortReason,
    },
    Cancelled,
    Terminal(Box<json_v2::TerminalFrame>),
    // --- v1 ---
    AcceptedV1,
    CompleteV1 {
        usage: Option<json_v1::UsageInfo>,
        se_signature: Option<String>,
        response_hash: Option<String>,
    },
    ErrorV1 {
        status_code: u16,
        message: String,
    },
    // --- transport ---
    /// The provider session ended (any epoch teardown).
    SessionLost,
    /// The chunk pipe rejected a chunk: consumer backpressure (plan §13.6).
    PipeOverflow,
}

/// Sinks a request task registers with the session for one attempt.
pub struct AttemptSinks {
    /// Control events (bounded; the session drops the attempt on overflow and
    /// emits `SessionLost` semantics rather than blocking its read loop).
    pub events: mpsc::Sender<AttemptEvent>,
    /// Content chunks, decrypted for v1 / raw ciphertext for v2 relay.
    pub chunks: ChunkSender,
}

/// Commands consumed by one provider session's demux/writer loops.
#[derive(Debug)]
pub enum SessionCommand {
    AttachAttempt {
        /// v1 request id or v2 attempt id in wire form, used for demux.
        wire_id: String,
        attempt: AttemptId,
        sinks: AttemptSinksHandle,
    },
    DetachAttempt {
        wire_id: String,
    },
}

/// Debug-friendly wrapper because `AttemptSinks` contains non-Debug senders.
pub struct AttemptSinksHandle(pub AttemptSinks);

impl std::fmt::Debug for AttemptSinksHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("AttemptSinksHandle")
    }
}

/// Clonable handle to one provider session. All submission is bounded and
/// non-blocking at the call site; wire completion is observed via [`OnWire`].
#[derive(Clone)]
pub struct SessionHandle {
    pub provider: ProviderId,
    pub epoch: SessionEpoch,
    pub protocol: ProtocolGen,
    control_tx: mpsc::Sender<(ControlFrame, oneshot::Sender<Result<(), WriteError>>)>,
    data_tx: mpsc::Sender<(DataFrame, oneshot::Sender<Result<(), WriteError>>)>,
    command_tx: mpsc::Sender<SessionCommand>,
}

/// Receiver ends consumed by the session's writer and demux loops.
pub struct SessionReceivers {
    pub control_rx: mpsc::Receiver<(ControlFrame, oneshot::Sender<Result<(), WriteError>>)>,
    pub data_rx: mpsc::Receiver<(DataFrame, oneshot::Sender<Result<(), WriteError>>)>,
    pub command_rx: mpsc::Receiver<SessionCommand>,
}

/// Lane capacities (plan §14): control small, data a few full frames.
#[derive(Debug, Clone, Copy)]
pub struct SessionLaneCaps {
    pub control: usize,
    pub data: usize,
    pub commands: usize,
}

impl Default for SessionLaneCaps {
    fn default() -> Self {
        Self {
            control: 64,
            data: 4,
            commands: 64,
        }
    }
}

/// Builds the channel pair for one session.
pub fn session_channels(
    provider: ProviderId,
    epoch: SessionEpoch,
    protocol: ProtocolGen,
    caps: SessionLaneCaps,
) -> (SessionHandle, SessionReceivers) {
    let (control_tx, control_rx) = mpsc::channel(caps.control);
    let (data_tx, data_rx) = mpsc::channel(caps.data);
    let (command_tx, command_rx) = mpsc::channel(caps.commands);
    (
        SessionHandle {
            provider,
            epoch,
            protocol,
            control_tx,
            data_tx,
            command_tx,
        },
        SessionReceivers {
            control_rx,
            data_rx,
            command_rx,
        },
    )
}

#[derive(Debug, thiserror::Error)]
pub enum SubmitError {
    #[error("lane full")]
    LaneFull,
    #[error("session closed")]
    Closed,
}

impl SessionHandle {
    /// Enqueue on the control lane. A full control lane is a session-fencing
    /// condition (plan §9.4.3) — the CALLER treats `LaneFull` accordingly.
    pub fn submit_control(&self, frame: ControlFrame) -> Result<OnWire, SubmitError> {
        let (tx, rx) = oneshot::channel();
        self.control_tx
            .try_send((frame, tx))
            .map_err(map_try_send)?;
        Ok(rx)
    }

    /// Enqueue on the data lane. A full data lane makes the provider
    /// temporarily ineligible (plan §9.4.2); callers fail fast.
    pub fn submit_data(&self, frame: DataFrame) -> Result<OnWire, SubmitError> {
        let (tx, rx) = oneshot::channel();
        self.data_tx.try_send((frame, tx)).map_err(map_try_send)?;
        Ok(rx)
    }

    /// True when the data lane currently has headroom (admission gate input).
    pub fn data_lane_has_headroom(&self) -> bool {
        self.data_tx.capacity() > 0
    }

    pub fn control_lane_has_headroom(&self) -> bool {
        self.control_tx.capacity() > 0
    }

    pub async fn attach_attempt(
        &self,
        wire_id: String,
        attempt: AttemptId,
        sinks: AttemptSinks,
    ) -> Result<(), SubmitError> {
        self.command_tx
            .send(SessionCommand::AttachAttempt {
                wire_id,
                attempt,
                sinks: AttemptSinksHandle(sinks),
            })
            .await
            .map_err(|_| SubmitError::Closed)
    }

    pub async fn detach_attempt(&self, wire_id: String) -> Result<(), SubmitError> {
        self.command_tx
            .send(SessionCommand::DetachAttempt { wire_id })
            .await
            .map_err(|_| SubmitError::Closed)
    }
}

fn map_try_send<T>(err: mpsc::error::TrySendError<T>) -> SubmitError {
    match err {
        mpsc::error::TrySendError::Full(_) => SubmitError::LaneFull,
        mpsc::error::TrySendError::Closed(_) => SubmitError::Closed,
    }
}

// ---------------------------------------------------------------------------
// Bounded consumer byte pipe (plan §13.6, §14)
// ---------------------------------------------------------------------------

/// One content chunk flowing provider -> consumer.
#[derive(Debug, Clone)]
pub struct ChunkFrame {
    /// SSE-ready plaintext payload (v1: decrypted chunk JSON; v2: decrypted
    /// or relay bytes depending on the egress mode).
    pub payload: Bytes,
    /// v2 sequence number; 0 for v1.
    pub sequence: u64,
    /// v2 cumulative completion tokens at this chunk; 0 for v1.
    pub cumulative_tokens: u64,
}

/// Byte-accounted bounded pipe. `try_send` never blocks: the pipe IS the
/// grace window (plan §13.6) — size it for multi-second burst absorption.
pub fn chunk_pipe(max_items: usize, max_bytes: usize) -> (ChunkSender, ChunkReceiver) {
    let (tx, rx) = mpsc::channel(max_items.max(1));
    let bytes = Arc::new(AtomicUsize::new(0));
    (
        ChunkSender {
            tx,
            bytes: bytes.clone(),
            max_bytes,
        },
        ChunkReceiver { rx, bytes },
    )
}

#[derive(Clone)]
pub struct ChunkSender {
    tx: mpsc::Sender<ChunkFrame>,
    bytes: Arc<AtomicUsize>,
    max_bytes: usize,
}

#[derive(Debug, thiserror::Error)]
pub enum PipeError {
    #[error("pipe full")]
    Full,
    #[error("pipe closed")]
    Closed,
}

impl ChunkSender {
    /// Nonblocking send with byte accounting. On `Full` the caller cancels
    /// the provider and fails the request — never silently drops (plan §13.6).
    pub fn try_send(&self, frame: ChunkFrame) -> Result<(), PipeError> {
        let len = frame.payload.len();
        let prev = self.bytes.fetch_add(len, Ordering::AcqRel);
        if prev + len > self.max_bytes {
            self.bytes.fetch_sub(len, Ordering::AcqRel);
            return Err(PipeError::Full);
        }
        match self.tx.try_send(frame) {
            Ok(()) => Ok(()),
            Err(mpsc::error::TrySendError::Full(f)) => {
                self.bytes.fetch_sub(f.payload.len(), Ordering::AcqRel);
                Err(PipeError::Full)
            }
            Err(mpsc::error::TrySendError::Closed(f)) => {
                self.bytes.fetch_sub(f.payload.len(), Ordering::AcqRel);
                Err(PipeError::Closed)
            }
        }
    }
}

pub struct ChunkReceiver {
    rx: mpsc::Receiver<ChunkFrame>,
    bytes: Arc<AtomicUsize>,
}

impl ChunkReceiver {
    pub async fn recv(&mut self) -> Option<ChunkFrame> {
        let frame = self.rx.recv().await?;
        self.bytes.fetch_sub(frame.payload.len(), Ordering::AcqRel);
        Some(frame)
    }
}

// ---------------------------------------------------------------------------
// Fleet actor seam (plan §7.3, §11)
// ---------------------------------------------------------------------------

/// Registration summary the session hands the fleet on connect.
///
/// `provider` is the stable identity as a [`ProviderId`] (UUID). Wire
/// identities are strings (serial / SE-key hash); the session derives the
/// UUID deterministically via UUIDv5 over the stable identity string
/// (`provider_session::stable_provider_id`).
#[derive(Debug, Clone)]
pub struct RegistrationSummary {
    pub provider: ProviderId,
    /// Raw stable identity string as seen on the wire (for logs/DB rows).
    pub wire_identity: String,
    pub protocol: ProtocolGen,
    pub version: String,
    pub public_key_b64: String,
    pub models: Vec<ModelId>,
    pub beneficiary: Option<AccountId>,
    pub capabilities: Vec<String>,
}

/// What admit returns on success (plan §7.8 step 2): a permit plus the
/// frozen quote reference and the live session handle.
pub struct AdmitGrant {
    pub permit: DispatchPermit,
    pub provider: ProviderId,
    pub session: SessionHandle,
    pub concrete_model: ModelId,
    pub price: PriceCard,
    pub beneficiary: Option<AccountId>,
    /// Predicted first-content latency for hedge/deadline math.
    pub predicted_first_content: Duration,
}

pub enum AdmitOutcome {
    Grant(Box<AdmitGrant>),
    RetryAfter { reason: String, delay: Duration },
    Reject(RejectionReason),
}

#[derive(Debug, Clone)]
pub struct AdmitRequest {
    pub job: JobId,
    pub model: ModelId,
    pub traits: RequestTraits,
    pub estimated_prompt_tokens: u64,
    pub requested_max_tokens: u64,
    /// Providers already attempted for this job (alternate/hedge exclusion).
    pub exclude: Vec<ProviderId>,
    pub paid: bool,
}

/// Health/telemetry observations reduced by the fleet actor.
#[derive(Debug, Clone)]
pub enum FleetObservation {
    PrepareRejected {
        provider: ProviderId,
        model: ModelId,
        class: json_v2::ErrorClass,
    },
    ProviderFault {
        provider: ProviderId,
        model: ModelId,
    },
    FirstContent {
        provider: ProviderId,
        model: ModelId,
        predicted: Duration,
        actual: Duration,
    },
    SecurityFence {
        provider: ProviderId,
    },
}

/// Reliable-lane fleet commands (plan §14: lifecycle/admission lane).
pub enum FleetCommand {
    Admit {
        req: AdmitRequest,
        reply: oneshot::Sender<AdmitOutcome>,
    },
    ReleasePermit {
        provider: ProviderId,
        permit: PermitId,
    },
    Connect {
        registration: Box<RegistrationSummary>,
        session_seed: Box<SessionSeed>,
        reply: oneshot::Sender<Result<ConnectAccept, ConnectRejected>>,
    },
    Disconnect {
        provider: ProviderId,
        epoch: SessionEpoch,
    },
    ModelLifecycle {
        provider: ProviderId,
        epoch: SessionEpoch,
        model: ModelId,
        ready: bool,
        revision: StateRevision,
    },
    TrustVerdict {
        provider: ProviderId,
        trust_epoch: TrustEpoch,
        verdict: TrustVerdict,
    },
    Observe(FleetObservation),
    /// Read-only snapshot for stats/admin endpoints.
    Snapshot {
        reply: oneshot::Sender<FleetSnapshot>,
    },
}

/// Everything the fleet needs to mint the session handle at connect time.
/// The fleet assigns the epoch (single authority — plan §9.1.1).
pub struct SessionSeed {
    pub protocol: ProtocolGen,
    pub lane_caps: SessionLaneCaps,
}

pub struct ConnectAccept {
    pub epoch: SessionEpoch,
    pub handle: SessionHandle,
    pub receivers: SessionReceivers,
}

#[derive(Debug, thiserror::Error)]
pub enum ConnectRejected {
    #[error("provider identity rejected: {0}")]
    Identity(String),
    #[error("fleet at session capacity")]
    Capacity,
}

#[derive(Debug, Clone)]
pub enum TrustVerdict {
    HardwareTrusted,
    SelfSigned,
    Untrusted { reason: String },
}

/// Coalesced advisory heartbeat (plan §14: separate coalesced lane).
#[derive(Debug, Clone)]
pub struct HeartbeatUpdate {
    pub provider: ProviderId,
    pub epoch: SessionEpoch,
    pub revision: StateRevision,
    pub candidate: CandidateSnapshot,
    pub models: Vec<(ModelId, bool)>,
}

#[derive(Debug, Clone, Default)]
pub struct FleetSnapshot {
    pub providers: usize,
    pub routable: usize,
    pub warm_by_model: std::collections::HashMap<String, usize>,
}

/// Clonable fleet handle.
#[derive(Clone)]
pub struct FleetHandle {
    pub commands: mpsc::Sender<FleetCommand>,
    pub heartbeats: mpsc::Sender<HeartbeatUpdate>,
}

pub struct FleetReceivers {
    pub commands: mpsc::Receiver<FleetCommand>,
    pub heartbeats: mpsc::Receiver<HeartbeatUpdate>,
}

pub fn fleet_channels(command_cap: usize, heartbeat_cap: usize) -> (FleetHandle, FleetReceivers) {
    let (ctx, crx) = mpsc::channel(command_cap);
    let (htx, hrx) = mpsc::channel(heartbeat_cap);
    (
        FleetHandle {
            commands: ctx,
            heartbeats: htx,
        },
        FleetReceivers {
            commands: crx,
            heartbeats: hrx,
        },
    )
}

impl FleetHandle {
    /// Admission fails fast when the mailbox is full (plan §14).
    pub async fn admit(&self, req: AdmitRequest) -> Result<AdmitOutcome, FleetUnavailable> {
        let (tx, rx) = oneshot::channel();
        self.commands
            .try_send(FleetCommand::Admit { req, reply: tx })
            .map_err(|_| FleetUnavailable)?;
        rx.await.map_err(|_| FleetUnavailable)
    }
}

#[derive(Debug, thiserror::Error)]
#[error("fleet actor unavailable")]
pub struct FleetUnavailable;

// ---------------------------------------------------------------------------
// Ledger facade (plan §7.5, §12)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct ReserveParams {
    pub operation_key: String,
    pub job: JobId,
    pub account: AccountId,
    pub api_key: Option<ApiKeyId>,
    pub public_model: String,
    pub concrete_model: String,
    pub hold: MicroUsd,
    pub spend_cap: Option<MicroUsd>,
    pub first_content_deadline_ms: i64,
    pub request_deadline_ms: i64,
    pub coordinator_epoch: CoordinatorEpoch,
}

#[derive(Debug, Clone, Copy)]
pub struct ReserveOutcome {
    pub reserved_total: MicroUsd,
    pub reserved_withdrawable: MicroUsd,
}

#[derive(Debug, Clone)]
pub struct ResizeFreezeParams {
    pub operation_key: String,
    pub job: JobId,
    pub attempt: AttemptId,
    pub new_hold: MicroUsd,
    pub frozen: FrozenTerms,
    pub lease: LeaseId,
    pub provider: ProviderId,
    pub coordinator_epoch: CoordinatorEpoch,
}

#[derive(Debug, Clone)]
pub struct SettleParams {
    pub operation_key: String,
    pub job: JobId,
    pub attempt: AttemptId,
    pub terminal_digest: [u8; 32],
    /// Raw terminal receipt for the durable table.
    pub terminal_json: serde_json::Value,
    pub prompt_tokens: u64,
    pub completion_tokens_claimed: u64,
    pub accepted_sequence: u64,
    pub accepted_cumulative_tokens: u64,
    pub coordinator_epoch: CoordinatorEpoch,
}

#[derive(Debug, Clone, Copy)]
pub struct SettleOutcome {
    pub charged: MicroUsd,
    pub refunded: MicroUsd,
    pub provider_payout: MicroUsd,
    pub flagged_for_review: bool,
}

#[derive(Debug, Clone)]
pub struct ReleaseParams {
    pub operation_key: String,
    pub job: JobId,
    pub reason: String,
    pub coordinator_epoch: CoordinatorEpoch,
}

#[derive(Debug, thiserror::Error)]
pub enum LedgerError {
    #[error("insufficient funds")]
    InsufficientFunds,
    #[error("spend cap exceeded")]
    SpendCapExceeded,
    #[error("state conflict: {0}")]
    Conflict(String),
    #[error("coordinator epoch fenced")]
    EpochFenced,
    #[error("database unavailable: {0}")]
    Unavailable(String),
}

/// Narrow async ledger seam (plan §7.5). Implemented by `ledger::Ledger`
/// over SQLx; request tasks depend only on this trait so the components can
/// be developed and tested independently.
#[async_trait::async_trait]
pub trait LedgerFacade: Send + Sync {
    async fn reserve(&self, p: ReserveParams) -> Result<ReserveOutcome, LedgerError>;
    async fn resize_freeze(&self, p: ResizeFreezeParams) -> Result<(), LedgerError>;
    async fn mark_running(&self, job: JobId) -> Result<(), LedgerError>;
    async fn settle(&self, p: SettleParams) -> Result<SettleOutcome, LedgerError>;
    async fn release(&self, p: ReleaseParams) -> Result<(), LedgerError>;
    async fn move_to_review(&self, job: JobId, reason: String) -> Result<(), LedgerError>;
}

// ---------------------------------------------------------------------------
// Auth seam
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct ApiKeyRecord {
    pub key_id: ApiKeyId,
    pub account: AccountId,
    pub spend_cap: Option<MicroUsd>,
    pub disabled: bool,
}

#[async_trait::async_trait]
pub trait ApiKeyStore: Send + Sync {
    /// Returns None for unknown/invalid tokens. Implementations cache.
    async fn validate(&self, token: &str) -> Option<ApiKeyRecord>;
}

// ---------------------------------------------------------------------------
// Shared application state (constructed in main, read by http)
// ---------------------------------------------------------------------------

#[derive(Clone)]
pub struct AppState {
    pub fleet: FleetHandle,
    pub ledger: Arc<dyn LedgerFacade>,
    pub keys: Arc<dyn ApiKeyStore>,
    pub catalog: SharedCatalog,
    pub policy: Arc<RequestPolicy>,
    pub coordinator_epoch: CoordinatorEpoch,
    /// Coordinator X25519 identity for provider-bound encryption.
    pub encryption: Arc<CoordinatorKeys>,
    pub admission_config: Arc<AdmissionConfig>,
}

/// Coordinator key material. Secret bytes zeroized on drop by the crypto
/// layer; only the protocol crate touches raw secrets.
pub struct CoordinatorKeys {
    pub x25519_public_b64: String,
    pub x25519_secret: darkbloom_protocol::crypto::nacl_box::SecretKey,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn chunk_pipe_enforces_byte_budget() {
        let (tx, mut rx) = chunk_pipe(16, 10);
        tx.try_send(ChunkFrame {
            payload: Bytes::from_static(b"123456"),
            sequence: 1,
            cumulative_tokens: 1,
        })
        .unwrap();
        // 6 + 6 > 10: second send must fail without dropping the first.
        let err = tx
            .try_send(ChunkFrame {
                payload: Bytes::from_static(b"123456"),
                sequence: 2,
                cumulative_tokens: 2,
            })
            .unwrap_err();
        assert!(matches!(err, PipeError::Full));
        let got = rx.recv().await.unwrap();
        assert_eq!(got.sequence, 1);
        // Draining frees budget.
        tx.try_send(ChunkFrame {
            payload: Bytes::from_static(b"123456"),
            sequence: 3,
            cumulative_tokens: 3,
        })
        .unwrap();
    }

    #[tokio::test]
    async fn session_lanes_report_headroom() {
        let (handle, _rx) = session_channels(
            ProviderId::new(uuid::Uuid::from_u128(1)),
            SessionEpoch::new(1),
            ProtocolGen::V2,
            SessionLaneCaps {
                control: 1,
                data: 1,
                commands: 1,
            },
        );
        assert!(handle.data_lane_has_headroom());
        let _wire = handle
            .submit_data(DataFrame::RawJson(Bytes::from_static(b"{}")))
            .unwrap();
        assert!(!handle.data_lane_has_headroom());
        let err = handle
            .submit_data(DataFrame::RawJson(Bytes::from_static(b"{}")))
            .unwrap_err();
        assert!(matches!(err, SubmitError::LaneFull));
    }
}
