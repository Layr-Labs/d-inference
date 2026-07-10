//! Immutable provider circuit-breaker health state.

use serde::Serialize;
use thiserror::Error;

use crate::{
    deadline::{DurationMillis, EpochMillis},
    ids::PermitId,
};

/// Circuit-breaker mode.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum HealthMode {
    /// Normal traffic is eligible.
    Closed {
        /// Consecutive failures since the last success.
        consecutive_failures: u32,
    },
    /// Traffic is blocked until the retry instant.
    Open {
        /// Earliest instant at which a probe may be prepared.
        retry_at: EpochMillis,
    },
    /// Normal traffic is blocked and at most one probe may be in flight.
    HalfOpen {
        /// Sole in-flight probe, or `None` before one is acquired.
        probe: Option<ProbeClaim>,
    },
}

/// Bounded ownership of the sole half-open probe.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub struct ProbeClaim {
    permit_id: PermitId,
    expires_at: EpochMillis,
}

impl ProbeClaim {
    /// Returns the permit that owns this claim.
    #[must_use]
    pub const fn permit_id(self) -> PermitId {
        self.permit_id
    }

    /// Returns the instant at which the claim becomes reclaimable.
    #[must_use]
    pub const fn expires_at(self) -> EpochMillis {
        self.expires_at
    }
}

/// Immutable provider health aggregate.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub struct HealthState {
    mode: HealthMode,
    last_observed_at: Option<EpochMillis>,
}

impl Default for HealthState {
    fn default() -> Self {
        Self::new()
    }
}

impl HealthState {
    /// Creates a healthy closed circuit.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            mode: HealthMode::Closed {
                consecutive_failures: 0,
            },
            last_observed_at: None,
        }
    }

    /// Returns the circuit mode.
    #[must_use]
    pub const fn mode(self) -> HealthMode {
        self.mode
    }

    /// Returns whether ordinary requests may be admitted.
    #[must_use]
    pub const fn admits_regular_traffic(self) -> bool {
        matches!(self.mode, HealthMode::Closed { .. })
    }
}

/// Circuit-breaker policy.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct HealthPolicy {
    failure_threshold: u32,
    open_duration: DurationMillis,
    probe_timeout: DurationMillis,
}

impl HealthPolicy {
    /// Maximum time a dropped probe may block the half-open circuit.
    pub const MAX_PROBE_TIMEOUT_MILLIS: u64 = 5 * 60 * 1_000;

    /// Creates a policy with a nonzero failure threshold.
    pub const fn new(
        failure_threshold: u32,
        open_duration: DurationMillis,
        probe_timeout: DurationMillis,
    ) -> Result<Self, HealthError> {
        if failure_threshold == 0 {
            Err(HealthError::ZeroFailureThreshold)
        } else if probe_timeout.get() > Self::MAX_PROBE_TIMEOUT_MILLIS {
            Err(HealthError::ProbeTimeoutTooLong)
        } else {
            Ok(Self {
                failure_threshold,
                open_duration,
                probe_timeout,
            })
        }
    }
}

/// One circuit-breaker transition.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HealthEvent {
    /// A normal request succeeded while closed.
    Success {
        /// Observation time.
        now: EpochMillis,
    },
    /// A normal request failed while closed.
    Failure {
        /// Observation time.
        now: EpochMillis,
    },
    /// Advances an open circuit to half-open when its cooldown elapsed.
    Tick {
        /// Observation time.
        now: EpochMillis,
    },
    /// Atomically claims the sole half-open probe.
    ProbeAcquired {
        /// Observation time.
        now: EpochMillis,
        /// Probe permit identity.
        permit_id: PermitId,
    },
    /// Closes the circuit after the matching probe succeeds.
    ProbeSucceeded {
        /// Observation time.
        now: EpochMillis,
        /// Probe permit identity.
        permit_id: PermitId,
    },
    /// Reopens the circuit after the matching probe fails.
    ProbeFailed {
        /// Observation time.
        now: EpochMillis,
        /// Probe permit identity.
        permit_id: PermitId,
    },
}

impl HealthEvent {
    const fn now(self) -> EpochMillis {
        match self {
            Self::Success { now }
            | Self::Failure { now }
            | Self::Tick { now }
            | Self::ProbeAcquired { now, .. }
            | Self::ProbeSucceeded { now, .. }
            | Self::ProbeFailed { now, .. } => now,
        }
    }
}

/// Applies one health transition without mutating the input.
pub fn reduce(
    state: HealthState,
    event: HealthEvent,
    policy: HealthPolicy,
) -> Result<HealthState, HealthError> {
    let now = event.now();
    if state
        .last_observed_at
        .is_some_and(|previous| now < previous)
    {
        return Err(HealthError::ObservationTimeRegressed);
    }

    let mode = match (state.mode, event) {
        (HealthMode::Closed { .. }, HealthEvent::Success { .. }) => HealthMode::Closed {
            consecutive_failures: 0,
        },
        (
            HealthMode::Closed {
                consecutive_failures,
            },
            HealthEvent::Failure { .. },
        ) => {
            let failures = consecutive_failures
                .checked_add(1)
                .ok_or(HealthError::FailureCounterOverflow)?;
            if failures >= policy.failure_threshold {
                HealthMode::Open {
                    retry_at: now.checked_add(policy.open_duration)?,
                }
            } else {
                HealthMode::Closed {
                    consecutive_failures: failures,
                }
            }
        }
        (mode @ HealthMode::Closed { .. }, HealthEvent::Tick { .. }) => mode,
        (HealthMode::Open { retry_at }, HealthEvent::Tick { .. }) => {
            if now >= retry_at {
                HealthMode::HalfOpen { probe: None }
            } else {
                HealthMode::Open { retry_at }
            }
        }
        (HealthMode::HalfOpen { probe: None }, HealthEvent::ProbeAcquired { permit_id, .. }) => {
            HealthMode::HalfOpen {
                probe: Some(ProbeClaim {
                    permit_id,
                    expires_at: now.checked_add(policy.probe_timeout)?,
                }),
            }
        }
        (
            HealthMode::HalfOpen { probe: Some(claim) },
            HealthEvent::ProbeSucceeded { .. } | HealthEvent::ProbeFailed { .. },
        ) if now >= claim.expires_at => return Err(HealthError::ProbeExpired),
        (
            HealthMode::HalfOpen { probe: Some(claim) },
            HealthEvent::ProbeSucceeded { permit_id, .. },
        ) if claim.permit_id == permit_id => HealthMode::Closed {
            consecutive_failures: 0,
        },
        (
            HealthMode::HalfOpen { probe: Some(claim) },
            HealthEvent::ProbeFailed { permit_id, .. },
        ) if claim.permit_id == permit_id => HealthMode::Open {
            retry_at: now.checked_add(policy.open_duration)?,
        },
        (HealthMode::HalfOpen { probe: Some(_) }, HealthEvent::ProbeAcquired { .. }) => {
            return Err(HealthError::ProbeAlreadyInFlight);
        }
        (HealthMode::HalfOpen { probe: None }, HealthEvent::ProbeSucceeded { .. })
        | (HealthMode::HalfOpen { probe: None }, HealthEvent::ProbeFailed { .. }) => {
            return Err(HealthError::NoProbeInFlight);
        }
        (
            HealthMode::HalfOpen { probe: Some(claim) },
            HealthEvent::ProbeSucceeded { permit_id, .. }
            | HealthEvent::ProbeFailed { permit_id, .. },
        ) => {
            return Err(HealthError::ProbePermitMismatch {
                expected: claim.permit_id,
                supplied: permit_id,
            });
        }
        (HealthMode::HalfOpen { probe: Some(claim) }, HealthEvent::Tick { .. })
            if now >= claim.expires_at =>
        {
            HealthMode::HalfOpen { probe: None }
        }
        (mode @ HealthMode::HalfOpen { .. }, HealthEvent::Tick { .. }) => mode,
        _ => return Err(HealthError::InvalidTransition),
    };

    Ok(HealthState {
        mode,
        last_observed_at: Some(now),
    })
}

/// Invalid health transition or arithmetic.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum HealthError {
    /// Opening requires a positive number of failures.
    #[error("health failure threshold must be greater than zero")]
    ZeroFailureThreshold,
    /// Probe claims must remain promptly reclaimable.
    #[error("health probe timeout exceeds five minutes")]
    ProbeTimeoutTooLong,
    /// Failure count cannot wrap.
    #[error("health failure counter overflow")]
    FailureCounterOverflow,
    /// Event time moved backwards.
    #[error("health observation time regressed")]
    ObservationTimeRegressed,
    /// This event is not legal in the current circuit mode.
    #[error("invalid health-state transition")]
    InvalidTransition,
    /// The single half-open probe has already been claimed.
    #[error("half-open probe is already in flight")]
    ProbeAlreadyInFlight,
    /// A probe result arrived before a probe was acquired.
    #[error("no half-open probe is in flight")]
    NoProbeInFlight,
    /// A result did not match the sole probe permit.
    #[error("probe permit mismatch: expected {expected}, got {supplied}")]
    ProbePermitMismatch {
        /// In-flight permit.
        expected: PermitId,
        /// Result permit.
        supplied: PermitId,
    },
    /// A result arrived after the probe claim expired.
    #[error("half-open probe claim expired")]
    ProbeExpired,
    /// Cooldown timestamp overflowed.
    #[error(transparent)]
    Deadline(#[from] crate::deadline::DeadlineError),
}

#[cfg(test)]
mod tests {
    use super::{HealthError, HealthEvent, HealthMode, HealthPolicy, HealthState, reduce};
    use crate::{
        deadline::{DurationMillis, EpochMillis},
        ids::PermitId,
    };

    fn policy() -> HealthPolicy {
        HealthPolicy::new(
            2,
            DurationMillis::new(10).expect("nonzero test duration"),
            DurationMillis::new(5).expect("nonzero probe timeout"),
        )
        .expect("valid policy")
    }

    #[test]
    fn probe_timeout_is_finitely_bounded() {
        assert_eq!(
            HealthPolicy::new(
                1,
                DurationMillis::new(1).expect("nonzero"),
                DurationMillis::new(HealthPolicy::MAX_PROBE_TIMEOUT_MILLIS + 1).expect("nonzero"),
            ),
            Err(HealthError::ProbeTimeoutTooLong)
        );
    }

    #[test]
    fn exactly_one_half_open_probe_is_allowed() {
        let state = reduce(
            HealthState::new(),
            HealthEvent::Failure {
                now: EpochMillis::new(1),
            },
            policy(),
        )
        .expect("first failure");
        let state = reduce(
            state,
            HealthEvent::Failure {
                now: EpochMillis::new(2),
            },
            policy(),
        )
        .expect("opens");
        assert!(matches!(state.mode(), HealthMode::Open { .. }));
        let state = reduce(
            state,
            HealthEvent::Tick {
                now: EpochMillis::new(12),
            },
            policy(),
        )
        .expect("half opens");
        let permit = PermitId::random();
        let state = reduce(
            state,
            HealthEvent::ProbeAcquired {
                now: EpochMillis::new(12),
                permit_id: permit,
            },
            policy(),
        )
        .expect("first probe");
        assert_eq!(
            reduce(
                state,
                HealthEvent::ProbeAcquired {
                    now: EpochMillis::new(12),
                    permit_id: PermitId::random(),
                },
                policy(),
            ),
            Err(HealthError::ProbeAlreadyInFlight)
        );
    }
}
