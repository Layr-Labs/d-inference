//! The `FleetActor`: one nonblocking task owning all live fleet decision
//! state (plan §7.3, §11, §14).
//!
//! The actor owns (single-threaded inside the task — no locks):
//!
//! - the provider map keyed by stable [`ProviderId`]: current session epoch
//!   and [`SessionHandle`], trust state with monotonic [`TrustEpoch`]
//!   fencing (plan §9.1.6), the canonical revision-fenced
//!   [`ProviderModelPresence`] (plan §10.7), the latest advisory
//!   [`CandidateSnapshot`] from heartbeats, and per (provider, model)
//!   [`HealthState`] machines (plan §11.6);
//! - the fleet-wide [`PermitBook`] (plan §9.2.10, §11.3);
//! - the [`CalibrationTable`] per (model, hardware class) (plan §11.4);
//! - the global [`HedgeBudget`] (plan §11.8) — accrued here per admission;
//!   the acquisition seam belongs to the request task's hedge timer and is
//!   wired at integration.
//!
//! All decision logic is `darkbloom_core::fleet` — this module only owns the
//! mutable maps and reduces commands/observations into them. Mailbox
//! discipline follows plan §14: a reliable lifecycle/admission command lane
//! with strict priority over the coalesced heartbeat lane; admission fails
//! fast when the command lane is full (`FleetHandle::admit` uses `try_send`).
//!
//! # Permit-id convention (contract note)
//!
//! [`contracts::AdmitGrant`] carries a [`DispatchPermit`] but the frozen
//! contract has no field for the minted [`PermitId`] the request task must
//! later pass to `FleetCommand::ReleasePermit`. Both sides therefore derive
//! it deterministically via [`permit_id_for`]`(job, provider)` — unique per
//! permit because a job never admits the same provider twice (the exclusion
//! set forbids re-selection).

mod actor;
mod admit;
mod connect;
mod observe;
mod state;

use std::time::Duration;

use tokio_util::sync::CancellationToken;

use darkbloom_core::fleet::admission::AdmissionConfig;
use darkbloom_core::fleet::calibration::CalibrationConfig;
use darkbloom_core::fleet::health::HealthConfig;
use darkbloom_core::fleet::hedge::{HedgeBudget, HedgeConfig};
use darkbloom_core::fleet::model_presence::ProviderModelPresence;
use darkbloom_core::fleet::permits::PermitBook;
#[allow(unused_imports)] // doc links
use darkbloom_core::fleet::{
    admission::CandidateSnapshot, calibration::CalibrationTable, health::HealthState,
};
use darkbloom_core::ids::{PermitId, ProviderId, TrustEpoch};

use crate::contracts::{self, FleetReceivers, SessionHandle, SharedCatalog};

pub use admit::permit_id_for;
pub(crate) use state::{
    HW_CLASS_CAPABILITY_PREFIX, SUPPORTS_MEDIA_CAPABILITY, SUPPORTS_TOOLS_CAPABILITY,
    SUPPORTS_VISION_CAPABILITY,
};

/// Trust level required for routing eligibility.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrustFloor {
    /// Local-dev only: every connected provider is routable and challenge
    /// freshness is not enforced.
    AllowUntrusted,
    /// Pilot default: a verified Secure Enclave attestation (`self_signed`)
    /// or better, with fresh challenge evidence.
    SelfSigned,
}

/// Actor tunables with pilot defaults.
#[derive(Debug, Clone)]
pub struct FleetTunables {
    pub trust_floor: TrustFloor,
    /// How long a trust stamp satisfies the challenge-freshness hard gate
    /// (challenges fire every ~5 min; default allows two missed rounds).
    pub challenge_freshness: Duration,
    pub health: HealthConfig,
    pub calibration: CalibrationConfig,
    pub hedge: HedgeConfig,
    /// `Connect` is rejected with `ConnectRejected::Capacity` beyond this.
    pub max_providers: usize,
    /// Outstanding-prepare bound used before the first heartbeat reports one.
    pub default_max_outstanding_permits: u32,
    /// Predicted first-content used before the first heartbeat reports one.
    pub default_predicted_first_content_ms: u64,
    /// Permit-expiry sweep and mailbox-depth metrics interval.
    pub sweep_interval: Duration,
}

impl Default for FleetTunables {
    fn default() -> Self {
        Self {
            trust_floor: TrustFloor::SelfSigned,
            challenge_freshness: Duration::from_secs(15 * 60),
            health: HealthConfig::default(),
            calibration: CalibrationConfig::default(),
            hedge: HedgeConfig::default(),
            max_providers: 10_000,
            default_max_outstanding_permits: 2,
            default_predicted_first_content_ms: 1_000,
            sweep_interval: Duration::from_secs(1),
        }
    }
}

/// Everything `spawn` needs. The receivers come from
/// [`contracts::fleet_channels`]; the matching [`contracts::FleetHandle`]
/// stays with the caller.
pub struct FleetConfig {
    pub receivers: FleetReceivers,
    pub admission: AdmissionConfig,
    pub catalog: SharedCatalog,
    pub cancel: CancellationToken,
    pub tunables: FleetTunables,
}

/// Handle to the running actor task.
pub struct FleetRuntime {
    handle: tokio::task::JoinHandle<()>,
    cancel: CancellationToken,
}

impl FleetRuntime {
    /// Cooperative shutdown: cancels the actor and joins it. Dropping every
    /// provider [`SessionHandle`] fences the live sessions (their lanes
    /// close), which is the supervisor's going-away trigger (plan §15.1).
    pub async fn shutdown(self) {
        self.cancel.cancel();
        let _ = self.handle.await;
    }

    /// The token that stops the actor (shared with [`FleetConfig::cancel`]).
    #[must_use]
    pub fn cancellation_token(&self) -> &CancellationToken {
        &self.cancel
    }
}

/// Spawns the single fleet actor task (plan §7.3: do not shard).
#[must_use]
pub fn spawn(cfg: FleetConfig) -> FleetRuntime {
    let FleetConfig {
        receivers,
        admission,
        catalog,
        cancel,
        tunables,
    } = cfg;
    let hedge = HedgeBudget::new(tunables.hedge);
    let state = state::FleetState {
        providers: std::collections::HashMap::new(),
        permits: PermitBook::new(),
        permit_meta: std::collections::HashMap::new(),
        calibration: darkbloom_core::fleet::calibration::CalibrationTable::new(),
        hedge,
        admission,
        catalog,
        tunables,
        counters: state::FleetCounters::default(),
        admit_seq: 0,
    };
    let actor = actor::Actor::new(state, receivers, cancel.clone());
    let handle = tokio::spawn(actor.run());
    FleetRuntime { handle, cancel }
}

/// Trust as the fleet tracks it: the latest epoch-fenced verdict plus the
/// stamp used for the challenge-freshness gate.
#[derive(Debug, Clone)]
pub(crate) struct TrustState {
    pub epoch: TrustEpoch,
    pub verdict: contracts::TrustVerdict,
    /// Set on every non-`Untrusted` verdict; the freshness gate compares it
    /// against [`FleetTunables::challenge_freshness`].
    pub stamped_at_ms: Option<i64>,
}

impl Default for TrustState {
    fn default() -> Self {
        Self {
            epoch: TrustEpoch::new(0),
            verdict: contracts::TrustVerdict::Untrusted {
                reason: "never verified".to_owned(),
            },
            stamped_at_ms: None,
        }
    }
}

/// One provider's live state. Trust, health, and the epoch high-water mark
/// survive disconnects; session, presence, and advisory state are per-epoch.
#[derive(Default)]
pub(crate) struct ProviderEntry {
    pub last_epoch: darkbloom_core::ids::SessionEpoch,
    pub session: Option<SessionHandle>,
    pub registration: Option<contracts::RegistrationSummary>,
    pub hardware_class: Option<darkbloom_core::ids::HardwareClass>,
    pub trust: TrustState,
    pub presence: ProviderModelPresence,
    pub advisory: Option<state::AdvisoryState>,
    pub health: std::collections::BTreeMap<
        darkbloom_core::ids::ModelId,
        darkbloom_core::fleet::health::HealthState,
    >,
    pub security: darkbloom_core::fleet::health::SecurityFence,
}

/// Metadata for one outstanding permit, kept so release/expiry can resolve
/// half-open probes and per-provider cleanup.
#[derive(Debug, Clone)]
pub(crate) struct PermitMeta {
    pub provider: ProviderId,
    pub model: darkbloom_core::ids::ModelId,
    pub is_probe: bool,
}

/// Outstanding-permit metadata index, keyed by the minted [`PermitId`].
pub(crate) type PermitMetaMap = std::collections::HashMap<PermitId, PermitMeta>;
