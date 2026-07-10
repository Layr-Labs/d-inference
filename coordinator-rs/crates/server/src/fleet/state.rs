//! Mutable actor state and small pure helpers (plan §7.3).
//!
//! Everything here is owned by the single actor task; nothing is shared or
//! locked. The decision logic lives in `darkbloom_core::fleet` — this file
//! only holds the maps it decides over.

use std::collections::HashMap;

use darkbloom_core::fleet::admission::{AdmissionConfig, CandidateSnapshot};
use darkbloom_core::fleet::calibration::CalibrationTable;
use darkbloom_core::fleet::hedge::HedgeBudget;
use darkbloom_core::fleet::permits::PermitBook;
use darkbloom_core::ids::{HardwareClass, ProviderId};
use darkbloom_core::time::{DurationMs, TimestampMs};

use crate::contracts::{SharedCatalog, TrustVerdict};

use super::{FleetTunables, PermitMetaMap, ProviderEntry, TrustFloor};

/// Advisory (heartbeat-sourced) view of one provider: never authoritative
/// (plan §11.3), refreshed wholesale by every accepted heartbeat. The
/// revision fence lives in the presence view, which shares the heartbeat's
/// revision domain.
#[derive(Debug, Clone)]
pub(crate) struct AdvisoryState {
    pub candidate: CandidateSnapshot,
}

/// Plain counters surfaced through `Snapshot` and the metrics sweep.
#[derive(Debug, Default, Clone, Copy)]
pub(crate) struct FleetCounters {
    pub admits_granted: u64,
    pub admits_retry: u64,
    pub admits_rejected: u64,
    pub heartbeats_applied: u64,
    pub heartbeats_stale: u64,
    pub stale_commands: u64,
    pub trust_verdicts_applied: u64,
    pub trust_verdicts_fenced: u64,
}

pub(crate) struct FleetState {
    pub providers: HashMap<ProviderId, ProviderEntry>,
    pub permits: PermitBook,
    pub permit_meta: PermitMetaMap,
    pub calibration: CalibrationTable,
    pub hedge: HedgeBudget,
    pub admission: AdmissionConfig,
    pub catalog: SharedCatalog,
    pub tunables: FleetTunables,
    pub counters: FleetCounters,
    /// Monotonic admission counter, folded into the tiebreak seed.
    pub admit_seq: u64,
}

impl FleetState {
    /// Whether this entry's trust satisfies the configured floor.
    pub(crate) fn trust_ok(&self, entry: &ProviderEntry) -> bool {
        match self.tunables.trust_floor {
            TrustFloor::AllowUntrusted => true,
            TrustFloor::SelfSigned => matches!(
                entry.trust.verdict,
                TrustVerdict::SelfSigned | TrustVerdict::HardwareTrusted
            ),
        }
    }

    /// Challenge-freshness hard gate (plan §11.2): the latest trust stamp
    /// must be recent. Under `AllowUntrusted` the gate is disabled.
    pub(crate) fn challenge_fresh(&self, entry: &ProviderEntry, now: TimestampMs) -> bool {
        match self.tunables.trust_floor {
            TrustFloor::AllowUntrusted => true,
            TrustFloor::SelfSigned => entry.trust.stamped_at_ms.is_some_and(|stamped| {
                let age = now.saturating_since(TimestampMs::new(stamped));
                age <= DurationMs::new(duration_to_ms(self.tunables.challenge_freshness))
            }),
        }
    }
}

/// Coordinator wall-clock in the core crate's millisecond domain. The core
/// never reads a clock; the actor stamps every reducer call explicitly.
pub(crate) fn now_ms() -> TimestampMs {
    TimestampMs::new(chrono::Utc::now().timestamp_millis())
}

/// `std::time::Duration` -> core milliseconds, saturating.
pub(crate) fn duration_to_ms(d: std::time::Duration) -> u64 {
    u64::try_from(d.as_millis()).unwrap_or(u64::MAX)
}

/// Capability marker carrying the provider hardware class through the frozen
/// [`crate::contracts::RegistrationSummary::capabilities`] list. The session
/// prepends `hw_class:<class>` (see `provider_session::registration`); the
/// calibration table keys on it (plan §11.4).
pub(crate) const HW_CLASS_CAPABILITY_PREFIX: &str = "hw_class:";

/// Trait-support markers carried the same way, so the hard trait gates
/// (plan §11.2) work from registration onward — before the first heartbeat
/// refreshes the advisory candidate (a v2 provider can become Ready via
/// lifecycle events alone).
pub(crate) const SUPPORTS_VISION_CAPABILITY: &str = "supports:vision";
pub(crate) const SUPPORTS_TOOLS_CAPABILITY: &str = "supports:tools";
pub(crate) const SUPPORTS_MEDIA_CAPABILITY: &str = "supports:media";

pub(crate) fn hardware_class_from_capabilities(capabilities: &[String]) -> Option<HardwareClass> {
    capabilities
        .iter()
        .find_map(|c| c.strip_prefix(HW_CLASS_CAPABILITY_PREFIX))
        .filter(|c| !c.is_empty())
        .map(HardwareClass::new)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hardware_class_marker_parses() {
        let caps = vec!["tools".to_owned(), "hw_class:m4-max".to_owned()];
        assert_eq!(
            hardware_class_from_capabilities(&caps),
            Some(HardwareClass::new("m4-max"))
        );
        assert_eq!(hardware_class_from_capabilities(&[]), None);
        assert_eq!(
            hardware_class_from_capabilities(&["hw_class:".to_owned()]),
            None
        );
    }
}
