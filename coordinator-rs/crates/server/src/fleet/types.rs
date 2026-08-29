//! Fleet configuration, runtime handle, and the shared per-provider state
//! shapes read across the actor's sibling modules.

use std::time::Duration;

use tokio_util::sync::CancellationToken;

use darkbloom_core::fleet::calibration::CalibrationConfig;
use darkbloom_core::fleet::health::HealthConfig;
use darkbloom_core::fleet::model_presence::ProviderModelPresence;
use darkbloom_core::ids::{PermitId, ProviderId, TrustEpoch};

use crate::contracts::{self, FleetReceivers, SessionHandle, SharedCatalog};

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
    pub admission: darkbloom_core::fleet::admission::AdmissionConfig,
    pub catalog: SharedCatalog,
    pub cancel: CancellationToken,
    pub tunables: FleetTunables,
}

/// Handle to the running actor task.
pub struct FleetRuntime {
    pub(super) handle: tokio::task::JoinHandle<()>,
    pub(super) cancel: CancellationToken,
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
    pub advisory: Option<super::state::AdvisoryState>,
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
