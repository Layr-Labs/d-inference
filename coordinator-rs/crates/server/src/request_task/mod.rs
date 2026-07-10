//! One supervised task per logical request (plan §7.2, §7.8, §10.3, §11.8,
//! §13): a thin async driver around the pure `darkbloom_core::request`
//! reducer. Events in, effects out; every lifecycle decision — funding CAS,
//! first-content commitment, the cancellation ladder, terminal disposition —
//! lives in the reducer, never here.
//!
//! # v1 attempt → reducer event mapping
//!
//! v1 sessions have no prepare/start protocol, so the task maps the legacy
//! wire flow onto the reducer without weakening any invariant:
//!
//! | wire moment | reducer event |
//! |---|---|
//! | `inference_request` submitted | attempt exists (`AdmitGranted` → `SendPrepare` executed as the v1 dispatch) |
//! | data-lane write confirmed | `PrepareWriteConfirmed` (ambiguous → `PrepareWriteUnknown`, plan §13.2) |
//! | `inference_accepted` | nothing — liveness only (Go parity) |
//! | first CONTENT chunk | synthetic `PreparedArrived` (minted lease, facts = reserve estimates, eta 0) → `FundAndAuthorize` executes as a NO-OP (the durable reserve IS the v1 funding leg; no resize) → `FundAuthorized` → `SendStart` executes as a no-op → `StartedAck` → `ContentAccepted` |
//! | role-only / lifecycle chunk | `PreambleAccepted` — held, does not commit (plan §9.2.7) |
//! | `inference_error` pre-content | `PrepareRejected { class }` (status-code classification) → invisible sequential alternate, mirroring Go pre-content failover |
//! | `inference_error` post-content | `TerminalArrived` (outcome `Error`, zero usage) |
//! | `inference_complete` pre-content | `PrepareRejected { Fault }` (zero-output stream) |
//! | `inference_complete` post-content | checkpoint promotion (see below) → `TerminalArrived` (outcome `Completed`, claimed usage) |
//! | v1 cancel (no ack exists) | bounded evidence wait, then `AttemptTimedOut` per open attempt |
//!
//! v1 checkpoint promotion: chunks precede `inference_complete` on the same
//! ordered socket, so when the stream is intact (no cancel, no backpressure)
//! the terminal's claimed completion count is accepted output and the
//! checkpoint is raised to it before settlement; a cancelled or stalled
//! stream settles capped at the accepted chunk count instead (plan §13.5,
//! §13.6).
//!
//! Prepare-stage hedging (plan §11.8) is v2-only: a v1 dispatch generates
//! immediately, so a v1 "hedge" would race two live generations — exactly
//! the retired Go behavior this design deletes.

mod attempt;
mod classify;
mod crypto;
mod driver;
mod funding;
mod terminal;
mod types;

use std::sync::{Arc, Mutex};

use darkbloom_core::fleet::admission::AdmissionConfig;
use darkbloom_core::fleet::hedge::{HedgeBudget, HedgeConfig};
use darkbloom_core::ids::{CoordinatorEpoch, ProviderId};
use tokio_util::sync::CancellationToken;

use crate::contracts::{
    AppState, CoordinatorKeys, FleetHandle, LedgerFacade, RequestPolicy, SharedCatalog,
};

pub use attempt::permit_id_for;
pub use classify::{classify, rewrite_chunk_model, strip_sse_prefix, ChunkClass};
pub use types::{Clock, ConsumerEvent, NormalizedRequest, TaskReport, UsageOut};

/// Provider X25519 key lookup. The frozen contracts do not carry the
/// provider's registered public key on the [`crate::contracts::AdmitGrant`],
/// and the request task owns per-request encryption (plan §15.4) — so this
/// seam is the local adaptation, wired at integration to the fleet/session
/// registry ([`crate::contracts::RegistrationSummary::public_key_b64`]).
pub trait ProviderKeyDirectory: Send + Sync {
    fn x25519_public_b64(&self, provider: ProviderId) -> Option<String>;
}

/// Static map implementation (tests, single-tenant tooling).
#[derive(Default)]
pub struct StaticProviderKeys(pub std::collections::HashMap<ProviderId, String>);

impl ProviderKeyDirectory for StaticProviderKeys {
    fn x25519_public_b64(&self, provider: ProviderId) -> Option<String> {
        self.0.get(&provider).cloned()
    }
}

/// Everything one request task needs (plan §7.2). Cheap to clone per
/// request.
#[derive(Clone)]
pub struct RequestTaskDeps {
    pub fleet: FleetHandle,
    pub ledger: Arc<dyn LedgerFacade>,
    pub catalog: SharedCatalog,
    pub policy: Arc<RequestPolicy>,
    pub admission_config: Arc<AdmissionConfig>,
    pub coordinator_epoch: CoordinatorEpoch,
    pub encryption: Arc<CoordinatorKeys>,
    pub provider_keys: Arc<dyn ProviderKeyDirectory>,
    /// Global bounded prepare-hedge budget (plan §11.8), shared across all
    /// request tasks.
    pub hedge_budget: Arc<Mutex<HedgeBudget>>,
    /// Coordinator shutdown: cancels the request like a consumer
    /// disconnect (plan §15.1 supervisor step 2).
    pub shutdown: CancellationToken,
}

impl RequestTaskDeps {
    /// Builds deps from the shared [`AppState`] plus the pieces the frozen
    /// contracts do not carry (provider keys, hedge budget, shutdown).
    pub fn from_state(
        state: &AppState,
        provider_keys: Arc<dyn ProviderKeyDirectory>,
        hedge_budget: Arc<Mutex<HedgeBudget>>,
        shutdown: CancellationToken,
    ) -> Self {
        Self {
            fleet: state.fleet.clone(),
            ledger: state.ledger.clone(),
            catalog: state.catalog.clone(),
            policy: state.policy.clone(),
            admission_config: state.admission_config.clone(),
            coordinator_epoch: state.coordinator_epoch,
            encryption: state.encryption.clone(),
            provider_keys,
            hedge_budget,
            shutdown,
        }
    }
}

/// Builds the process-wide hedge budget from the policy fraction
/// (plan §11.8: well under 10%, enforced by [`HedgeConfig`]).
pub fn shared_hedge_budget(policy: &RequestPolicy) -> Arc<Mutex<HedgeBudget>> {
    let fraction_ppm = (policy.hedge_budget_fraction.clamp(0.0, 0.099) * 1_000_000.0) as u32;
    let config =
        HedgeConfig::new(fraction_ppm.max(1), 4).unwrap_or_else(|_| HedgeConfig::default());
    Arc::new(Mutex::new(HedgeBudget::new(config)))
}

/// Runs one logical request to its single terminal disposition. The task
/// streams committed output through `req.consumer` and returns the final
/// [`TaskReport`]; when nothing was committed the HTTP adapter maps the
/// report to a status (plan §7.1).
pub async fn run(deps: RequestTaskDeps, req: NormalizedRequest) -> TaskReport {
    let job = req.job;
    let report = driver::Driver::new(deps, req).drive().await;
    tracing::debug!(
        %job,
        outcome = ?report.outcome,
        committed = report.committed,
        "request task finished"
    );
    report
}
