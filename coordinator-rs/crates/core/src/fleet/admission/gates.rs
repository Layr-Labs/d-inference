//! Hard eligibility gates (plan section 11.2): typed per-candidate failures
//! and the gate evaluation order.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use super::candidate::{CandidateSnapshot, RequestTraits};
use crate::fleet::health::HealthState;
use crate::ids::ProviderId;
use crate::time::TimestampMs;

/// Why one candidate failed a hard gate. Tallied into the rejection.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GateFailure {
    NoCurrentSession,
    Untrusted,
    ChallengeStale,
    RuntimeIntegrity,
    ModelNotReady,
    MissingVision,
    MissingTools,
    MissingMedia,
    MissingBeneficiary,
    Quarantined,
    ProbeOutstanding,
    SecurityFenced,
    DataLaneFull,
    ControlLaneFull,
    PermitsExhausted,
    AdvisoryCapacity,
    AlreadyAttempted,
}

impl GateFailure {
    /// Transient failures can clear on their own (load completes, permits
    /// drain, quarantine expires); they yield `RetryAfter`. Structural
    /// failures (trust, traits, beneficiary) yield `Reject`.
    #[must_use]
    pub(super) const fn is_transient(self) -> bool {
        match self {
            Self::ModelNotReady
            | Self::Quarantined
            | Self::ProbeOutstanding
            | Self::DataLaneFull
            | Self::ControlLaneFull
            | Self::PermitsExhausted
            | Self::AdvisoryCapacity
            | Self::AlreadyAttempted
            | Self::NoCurrentSession => true,
            Self::Untrusted
            | Self::ChallengeStale
            | Self::RuntimeIntegrity
            | Self::MissingVision
            | Self::MissingTools
            | Self::MissingMedia
            | Self::MissingBeneficiary
            | Self::SecurityFenced => false,
        }
    }
}

/// Evaluate every hard gate for one candidate (plan section 11.2). Returns
/// the first failure by severity order, tallying is done by the caller.
/// `Ok(is_probe)` marks a quarantine-expired candidate passing only as the
/// half-open probe.
pub(super) fn gate(
    traits: &RequestTraits,
    candidate: &CandidateSnapshot,
    exclude: &BTreeSet<ProviderId>,
    now: TimestampMs,
) -> Result<bool, GateFailure> {
    if exclude.contains(&candidate.provider) {
        return Err(GateFailure::AlreadyAttempted);
    }
    if !candidate.session_current {
        return Err(GateFailure::NoCurrentSession);
    }
    if candidate.security.is_fenced() {
        return Err(GateFailure::SecurityFenced);
    }
    if !candidate.trusted {
        return Err(GateFailure::Untrusted);
    }
    if !candidate.challenge_fresh {
        return Err(GateFailure::ChallengeStale);
    }
    if !candidate.runtime_integrity {
        return Err(GateFailure::RuntimeIntegrity);
    }
    if !candidate.model_presence.is_routable() {
        return Err(GateFailure::ModelNotReady);
    }
    if traits.needs_vision && !candidate.supports_vision {
        return Err(GateFailure::MissingVision);
    }
    if traits.needs_tools && !candidate.supports_tools {
        return Err(GateFailure::MissingTools);
    }
    if traits.needs_media && !candidate.supports_media {
        return Err(GateFailure::MissingMedia);
    }
    if traits.paid && candidate.beneficiary.is_none() {
        return Err(GateFailure::MissingBeneficiary);
    }
    if !candidate.data_lane_headroom {
        return Err(GateFailure::DataLaneFull);
    }
    if !candidate.control_lane_headroom {
        return Err(GateFailure::ControlLaneFull);
    }
    if candidate.outstanding_permits >= candidate.max_outstanding_permits {
        return Err(GateFailure::PermitsExhausted);
    }
    match candidate.health {
        HealthState::Healthy | HealthState::Suspect => Ok(false),
        HealthState::HalfOpen => Err(GateFailure::ProbeOutstanding),
        HealthState::Quarantined { .. } => {
            if candidate.health.probe_eligible(now) {
                Ok(true)
            } else {
                Err(GateFailure::Quarantined)
            }
        }
    }
}
