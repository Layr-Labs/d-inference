//! Per (provider, model) health state machine (plan section 11.6).
//!
//! ```text
//! healthy -> suspect -> quarantined{until} -> half_open{probe} -> healthy | quarantined
//! ```
//!
//! Invariants enforced by this reducer:
//!
//! - A quarantined pair can return to healthy only through a successful
//!   half-open probe; there is no quarantined -> healthy edge.
//! - Capacity rejection invalidates advisory capacity but is never a fault.
//! - `invalid_request` never affects health.
//! - Security faults are machine-wide, tracked as a separate flag outside
//!   this per-model machine (see [`SecurityFence`]).

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::provider_error::ProviderErrorClass;
use crate::time::{DurationMs, TimestampMs};

/// Health of one (provider, model) pair.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case", tag = "state")]
pub enum HealthState {
    #[default]
    Healthy,
    /// One recent fault. A success restores healthy; another fault
    /// quarantines.
    Suspect,
    /// No general traffic until `until`; after that, only a half-open probe.
    Quarantined { until: TimestampMs },
    /// One probe is outstanding. No other traffic routes to this pair.
    HalfOpen,
}

impl HealthState {
    /// Whether general (non-probe) traffic may route to this pair.
    #[must_use]
    pub fn admits_general_traffic(self) -> bool {
        matches!(self, Self::Healthy | Self::Suspect)
    }

    /// Whether a half-open probe may be dispatched at `now`
    /// (plan section 11.6: at most one explicit probe, only after expiry).
    #[must_use]
    pub fn probe_eligible(self, now: TimestampMs) -> bool {
        match self {
            Self::Quarantined { until } => now >= until,
            _ => false,
        }
    }
}

/// Machine-wide security fence (plan section 11.6: security state is separate
/// and machine-wide). Once fenced, only an explicit operator/trust-verifier
/// clear — outside this crate — lifts it; no health event does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum SecurityFence {
    #[default]
    Clear,
    Fenced,
}

impl SecurityFence {
    /// Reduce a provider error class into the machine-wide fence.
    #[must_use]
    pub fn observe(self, class: ProviderErrorClass) -> Self {
        match class {
            ProviderErrorClass::Security => Self::Fenced,
            _ => self,
        }
    }

    #[must_use]
    pub fn is_fenced(self) -> bool {
        matches!(self, Self::Fenced)
    }
}

/// Events that can move the per-model health machine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HealthEvent {
    /// A request on this pair completed successfully.
    Success,
    /// The provider reported a structured error for this pair. Only the
    /// `fault` class counts as a health fault; `capacity` invalidates
    /// advisory capacity elsewhere, `invalid_request` is ignored here.
    ProviderError(ProviderErrorClass),
    /// The fleet dispatched the single half-open probe.
    ProbeDispatched,
    /// The outstanding half-open probe succeeded.
    ProbeSucceeded,
    /// The outstanding half-open probe failed.
    ProbeFailed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum HealthTransitionError {
    #[error("probe dispatched while pair is not quarantine-expired")]
    ProbeNotEligible,
    #[error("probe result received while no probe is outstanding")]
    NoProbeOutstanding,
}

/// Tunables for fault handling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HealthConfig {
    /// How long a new quarantine lasts.
    pub quarantine: DurationMs,
}

impl Default for HealthConfig {
    fn default() -> Self {
        Self {
            quarantine: DurationMs::new(60_000),
        }
    }
}

/// Pure health reducer. Benign duplicates (success while healthy, fault
/// classes that do not affect health) are no-ops; structurally invalid probe
/// transitions are rejected with typed errors.
pub fn apply(
    state: HealthState,
    event: HealthEvent,
    now: TimestampMs,
    config: &HealthConfig,
) -> Result<HealthState, HealthTransitionError> {
    match event {
        HealthEvent::Success => Ok(match state {
            HealthState::Suspect => HealthState::Healthy,
            // A success cannot lift quarantine or resolve a probe: only the
            // explicit probe result can (invariant above).
            other => other,
        }),
        HealthEvent::ProviderError(class) => Ok(match class {
            ProviderErrorClass::Fault => match state {
                HealthState::Healthy => HealthState::Suspect,
                HealthState::Suspect => HealthState::Quarantined {
                    until: now.saturating_add(config.quarantine),
                },
                other => other,
            },
            // Capacity is advisory-only; invalid_request never affects
            // health; security is handled machine-wide; the rest are
            // routing outcomes, not health faults (plan sections 10.5, 11.6).
            _ => state,
        }),
        HealthEvent::ProbeDispatched => {
            if state.probe_eligible(now) {
                Ok(HealthState::HalfOpen)
            } else {
                Err(HealthTransitionError::ProbeNotEligible)
            }
        }
        HealthEvent::ProbeSucceeded => match state {
            HealthState::HalfOpen => Ok(HealthState::Healthy),
            _ => Err(HealthTransitionError::NoProbeOutstanding),
        },
        HealthEvent::ProbeFailed => match state {
            HealthState::HalfOpen => Ok(HealthState::Quarantined {
                until: now.saturating_add(config.quarantine),
            }),
            _ => Err(HealthTransitionError::NoProbeOutstanding),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: TimestampMs = TimestampMs::new(1_000);

    fn cfg() -> HealthConfig {
        HealthConfig::default()
    }

    #[test]
    fn two_faults_quarantine() {
        let s = apply(
            HealthState::Healthy,
            HealthEvent::ProviderError(ProviderErrorClass::Fault),
            NOW,
            &cfg(),
        )
        .expect("fault from healthy");
        assert_eq!(s, HealthState::Suspect);
        let s = apply(
            s,
            HealthEvent::ProviderError(ProviderErrorClass::Fault),
            NOW,
            &cfg(),
        )
        .expect("fault from suspect");
        assert!(matches!(s, HealthState::Quarantined { .. }));
    }

    #[test]
    fn capacity_and_invalid_request_do_not_affect_health() {
        for class in [
            ProviderErrorClass::Capacity,
            ProviderErrorClass::InvalidRequest,
        ] {
            let s = apply(
                HealthState::Healthy,
                HealthEvent::ProviderError(class),
                NOW,
                &cfg(),
            )
            .expect("non-fault class");
            assert_eq!(s, HealthState::Healthy);
        }
    }

    #[test]
    fn quarantine_requires_probe_to_recover() {
        let quarantined = HealthState::Quarantined {
            until: TimestampMs::new(2_000),
        };
        // Success alone cannot recover.
        let s = apply(
            quarantined,
            HealthEvent::Success,
            TimestampMs::new(5_000),
            &cfg(),
        )
        .expect("success is benign");
        assert_eq!(s, quarantined);
        // Probe before expiry is rejected.
        assert_eq!(
            apply(quarantined, HealthEvent::ProbeDispatched, NOW, &cfg()),
            Err(HealthTransitionError::ProbeNotEligible)
        );
        // Probe after expiry, then success, recovers.
        let s = apply(
            quarantined,
            HealthEvent::ProbeDispatched,
            TimestampMs::new(2_000),
            &cfg(),
        )
        .expect("probe after expiry");
        assert_eq!(s, HealthState::HalfOpen);
        let s = apply(
            s,
            HealthEvent::ProbeSucceeded,
            TimestampMs::new(2_100),
            &cfg(),
        )
        .expect("probe success");
        assert_eq!(s, HealthState::Healthy);
    }

    #[test]
    fn probe_failure_requarantines() {
        let s = apply(HealthState::HalfOpen, HealthEvent::ProbeFailed, NOW, &cfg())
            .expect("probe failure");
        assert!(matches!(s, HealthState::Quarantined { .. }));
    }

    #[test]
    fn security_fence_is_sticky() {
        let fence = SecurityFence::Clear.observe(ProviderErrorClass::Security);
        assert!(fence.is_fenced());
        assert!(fence.observe(ProviderErrorClass::Capacity).is_fenced());
    }
}
