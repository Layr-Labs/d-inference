//! The fleet-actor seam (plan §7.3, §11, §14): admission requests/grants,
//! connect/disconnect commands, health observations, trust verdicts, and
//! the coalesced heartbeat lane.

use std::time::Duration;

use tokio::sync::{mpsc, oneshot};

use darkbloom_core::fleet::admission::{
    CandidateSnapshot, DispatchPermit, RejectionReason, RequestTraits,
};
use darkbloom_core::ids::{
    AccountId, JobId, ModelId, PermitId, ProviderId, SessionEpoch, StateRevision, TrustEpoch,
};
use darkbloom_protocol::json_v2;

use super::policy::PriceCard;
use super::session::{ProtocolGen, SessionHandle, SessionLaneCaps, SessionReceivers};

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
    /// The permit id the fleet MINTED for this grant. The request task
    /// echoes exactly this id in [`FleetCommand::ReleasePermit`]; nothing
    /// re-derives it (plan §9.2.10 — the mint is the single identity).
    pub permit_id: PermitId,
    pub provider: ProviderId,
    pub session: SessionHandle,
    /// The provider's registered X25519 public key (base64), frozen at
    /// grant time from the same registration that owns `session` — so the
    /// key and the session epoch can never disagree (plan §15.4).
    pub provider_public_key_b64: String,
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
    /// Prepare permits currently outstanding fleet-wide (plan §9.2.10 —
    /// must return to zero when no request is in flight).
    pub permits_outstanding: usize,
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
