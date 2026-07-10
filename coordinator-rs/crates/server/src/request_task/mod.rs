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
//! | first CONTENT chunk | synthetic `PreparedArrived` (minted lease, facts = reserve estimates, eta 0) → `FundAndAuthorize` runs the SAME durable resize/freeze leg as v2 (facts are the reserve estimates, so the hold is unchanged; the leg freezes terms and records `start_authorized` — the durable state machine requires it before running/settlement) → `FundAuthorized` → `SendStart` executes as `mark_running` only → `StartedAck` → `ContentAccepted` |
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
//! v1 prompt billing basis: v1 providers have no signed exact tokenization,
//! so the frozen billable input IS the coordinator's estimate, and the
//! settlement claim echoes that estimate (the provider's self-reported
//! prompt count is stored in the terminal receipt for audit but never
//! billed and never review-flags a v1 job — the flag exists to catch v2
//! providers whose claim contradicts what THEY quoted at prepare).
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
use darkbloom_core::ids::CoordinatorEpoch;
use tokio_util::sync::CancellationToken;

use crate::contracts::{
    AppState, CoordinatorKeys, FleetHandle, LedgerFacade, RequestPolicy, SharedCatalog,
};

pub use classify::{classify, rewrite_chunk_model, strip_sse_prefix, ChunkClass};
pub use types::{Clock, ConsumerEvent, NormalizedRequest, TaskReport, UsageOut};

/// Everything one request task needs (plan §7.2). Cheap to clone per
/// request.
///
/// Provider encryption keys ride on [`crate::contracts::AdmitGrant`]
/// (`provider_public_key_b64`), frozen by the fleet at admit time from the
/// same registration that owns the granted session — there is no separate
/// key directory to fall out of sync with the session epoch.
#[derive(Clone)]
pub struct RequestTaskDeps {
    pub fleet: FleetHandle,
    pub ledger: Arc<dyn LedgerFacade>,
    pub catalog: SharedCatalog,
    pub policy: Arc<RequestPolicy>,
    pub admission_config: Arc<AdmissionConfig>,
    pub coordinator_epoch: CoordinatorEpoch,
    pub encryption: Arc<CoordinatorKeys>,
    /// THE global bounded prepare-hedge budget (plan §11.8), shared across
    /// all request tasks. Single authority: the fleet keeps no hedge
    /// accounting; `http::build_router_with` constructs exactly one of
    /// these per process from the policy fraction.
    pub hedge_budget: Arc<Mutex<HedgeBudget>>,
    /// Coordinator shutdown: cancels the request like a consumer
    /// disconnect (plan §15.1 supervisor step 2).
    pub shutdown: CancellationToken,
}

impl RequestTaskDeps {
    /// Builds deps from the shared [`AppState`] plus the pieces it does not
    /// carry (hedge budget, shutdown).
    pub fn from_state(
        state: &AppState,
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
            hedge_budget,
            shutdown,
        }
    }
}

/// Builds the process-wide hedge budget from the policy fraction
/// (plan §11.8: well under 10%, enforced by [`HedgeConfig`]). Construct
/// exactly ONE per process and share it through [`RequestTaskDeps`].
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
