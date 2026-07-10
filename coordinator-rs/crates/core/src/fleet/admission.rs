//! One pure admission operation (plan sections 11.1-11.4, 11.6, 11.7).
//!
//! `admit` performs, in order:
//!
//! 1. Hard eligibility gates (section 11.2) — typed, tallied per failure.
//! 2. Advisory warm/health filtering (transient, never authoritative).
//! 3. Scoring of the survivors (section 11.4, [`crate::fleet::scoring`]).
//! 4. A permit reservation *description* — the returned [`DispatchPermit`]
//!    tells the caller what to reserve in the [`crate::fleet::permits`]
//!    book; nothing is executed here.
//! 5. A typed decision: `Prepare`, `RetryAfter`, or `Reject`.
//!
//! There is no separate public preflight and committing reserve path; this
//! replaces the Go `QuickCapacityCheck` + `ReserveProviderEx` pair.
//!
//! Quarantine fail-open policy (section 11.6): if no healthy candidate
//! survives the gates but a quarantine-expired candidate exists, exactly one
//! half-open probe dispatch is offered (`DispatchPermit::is_probe`); all
//! other traffic gets `RetryAfter`.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::fleet::calibration::RatioPerMille;
use crate::fleet::health::{HealthState, SecurityFence};
use crate::fleet::model_presence::ModelPresence;
use crate::fleet::scoring::{score, select_best, Score, ScoreInputs, ScoringConfig};
use crate::ids::{AccountId, ModelId, ProviderId};
use crate::money::Tokens;
use crate::time::{DurationMs, TimestampMs};

/// Shape of the request being admitted (plan section 11.2 hard gates:
/// vision, tools, media, and other request traits).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestTraits {
    pub model: ModelId,
    pub needs_vision: bool,
    pub needs_tools: bool,
    pub needs_media: bool,
    /// Paid public routing requires a provider beneficiary identity.
    pub paid: bool,
    /// Measured per-model p50 output tokens (plan section 11.4: rank on the
    /// distribution, never the requested maximum).
    pub expected_output_tokens: Tokens,
}

/// One candidate as the fleet actor sees it at admission time. Everything
/// here is advisory input assembled by the caller; `admit` only decides.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CandidateSnapshot {
    pub provider: ProviderId,
    /// The provider has an active, current session epoch (plan 11.2).
    pub session_current: bool,
    /// Trust hard gate: verified trust at the required level.
    pub trusted: bool,
    /// Attestation challenge freshness hard gate.
    pub challenge_fresh: bool,
    /// Runtime and encrypted-transport integrity hard gate.
    pub runtime_integrity: bool,
    /// Canonical model presence for the requested model (plan 10.7).
    pub model_presence: ModelPresence,
    pub supports_vision: bool,
    pub supports_tools: bool,
    pub supports_media: bool,
    /// Beneficiary account for paid routing, when configured.
    pub beneficiary: Option<AccountId>,
    /// Per (provider, model) health state (plan 11.6).
    pub health: HealthState,
    /// Machine-wide security fence (plan 11.6).
    pub security: SecurityFence,
    /// Writer data-lane headroom flag (plan 9.4.2, 14).
    pub data_lane_headroom: bool,
    /// Writer control-lane headroom flag (plan 14: check both lanes).
    pub control_lane_headroom: bool,
    /// Prepare permits currently outstanding on this provider.
    pub outstanding_permits: u32,
    /// Advisory outstanding-prepare bound from heartbeat capacity (plan 11.3).
    pub max_outstanding_permits: u32,
    /// Advisory capacity says the provider can plausibly take this request.
    /// Invalidated by capacity rejections until fresh state arrives.
    pub advisory_capacity_ok: bool,
    /// Provider-estimated first-content latency (single occupancy signal).
    pub predicted_first_content: DurationMs,
    /// Measured decode rate, tokens/second; zero when unknown.
    pub decode_tokens_per_sec: u32,
    /// Clamped calibration correction for (model, hardware class), looked up
    /// by the caller from the [`crate::fleet::calibration::CalibrationTable`].
    pub calibration: RatioPerMille,
}

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
    const fn is_transient(self) -> bool {
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

/// Fully typed rejection (plan section 11.1).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum RejectionReason {
    /// No candidate exists for this model at all.
    NoCandidates,
    /// Every candidate failed a structural hard gate; the tally says why.
    AllGated {
        failures: BTreeMap<GateFailure, u32>,
    },
}

/// Why capacity-shaped traffic should retry (plan section 11.7).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CapacityReason {
    /// The model is not ready anywhere warm; placement gets the demand
    /// signal and the caller returns a load-time retry hint.
    ModelColdEverywhere,
    /// Warm capacity exists but is saturated (permits or writer lanes).
    FleetSaturated,
    /// Only quarantined pairs remain and no probe is currently possible.
    QuarantinedOnly,
}

/// The permit reservation this admission describes. The caller reserves it
/// in the permit book (mint a `PermitId`, call `reserve`) and dispatches
/// prepare; nothing has been mutated when this is returned.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DispatchPermit {
    pub provider: ProviderId,
    pub model: ModelId,
    /// Hard permit expiry (plan 9.2.10): `now + config.permit_ttl`.
    pub expires_at: TimestampMs,
    pub permit_ttl: DurationMs,
    /// True when this dispatch is the single half-open health probe
    /// (plan 11.6); the caller must also apply `HealthEvent::ProbeDispatched`.
    pub is_probe: bool,
    /// The scored estimate, for calibration feedback and telemetry.
    pub predicted_first_content: DurationMs,
}

/// The typed admission decision (plan section 11.1).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AdmissionDecision {
    Prepare(DispatchPermit),
    RetryAfter {
        reason: CapacityReason,
        delay: DurationMs,
    },
    Reject {
        reason: RejectionReason,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AdmissionConfig {
    pub scoring: ScoringConfig,
    /// Hard expiry for the described permit (plan 9.2.10).
    pub permit_ttl: DurationMs,
    /// Retry hint when the model is cold everywhere (load time scale).
    pub cold_model_delay: DurationMs,
    /// Retry hint when warm capacity is saturated.
    pub saturated_delay: DurationMs,
    /// Retry hint when only quarantined candidates remain.
    pub quarantined_delay: DurationMs,
}

impl Default for AdmissionConfig {
    fn default() -> Self {
        Self {
            scoring: ScoringConfig::default(),
            permit_ttl: DurationMs::new(10_000),
            cold_model_delay: DurationMs::new(30_000),
            saturated_delay: DurationMs::new(2_000),
            quarantined_delay: DurationMs::new(5_000),
        }
    }
}

/// Evaluate every hard gate for one candidate (plan section 11.2). Returns
/// the first failure by severity order, tallying is done by the caller.
/// `Ok(is_probe)` marks a quarantine-expired candidate passing only as the
/// half-open probe.
fn gate(
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

/// The one admission operation (plan section 11.1).
///
/// `exclude` is the set of already-attempted providers so the sequential
/// alternate and the prepare hedge never re-select the primary.
/// `tiebreak_seed` drives the near-tie spread; the function is pure — the
/// same inputs always yield the same decision.
#[must_use]
pub fn admit(
    traits: &RequestTraits,
    candidates: &[CandidateSnapshot],
    exclude: &BTreeSet<ProviderId>,
    config: &AdmissionConfig,
    now: TimestampMs,
    tiebreak_seed: u64,
) -> AdmissionDecision {
    if candidates.is_empty() {
        return AdmissionDecision::Reject {
            reason: RejectionReason::NoCandidates,
        };
    }

    let mut failures: BTreeMap<GateFailure, u32> = BTreeMap::new();
    let mut eligible: Vec<&CandidateSnapshot> = Vec::new();
    let mut probe_candidates: Vec<&CandidateSnapshot> = Vec::new();

    for candidate in candidates {
        match gate(traits, candidate, exclude, now) {
            Ok(false) => eligible.push(candidate),
            Ok(true) => probe_candidates.push(candidate),
            Err(failure) => {
                *failures.entry(failure).or_insert(0) += 1;
            }
        }
    }

    // Advisory filter (plan 11.1 step 2): transient, never authoritative.
    let (warm, advisory_filtered): (Vec<_>, Vec<_>) =
        eligible.into_iter().partition(|c| c.advisory_capacity_ok);
    if !advisory_filtered.is_empty() {
        *failures.entry(GateFailure::AdvisoryCapacity).or_insert(0) +=
            u32::try_from(advisory_filtered.len()).unwrap_or(u32::MAX);
    }

    if !warm.is_empty() {
        let scored: Vec<(ProviderId, Score)> = warm
            .iter()
            .map(|c| {
                let inputs = ScoreInputs {
                    predicted_first_content: c.predicted_first_content,
                    calibration: c.calibration,
                    decode_tokens_per_sec: c.decode_tokens_per_sec,
                    expected_output_tokens: traits.expected_output_tokens,
                    suspect: matches!(c.health, HealthState::Suspect),
                    outstanding_permits: c.outstanding_permits,
                };
                (c.provider, score(&inputs, &config.scoring))
            })
            .collect();
        // warm is non-empty, so a winner always exists.
        if let Some(winner) = select_best(&scored, &config.scoring, tiebreak_seed) {
            if let Some(chosen) = warm.iter().find(|c| c.provider == winner) {
                return AdmissionDecision::Prepare(permit_for(chosen, traits, config, now, false));
            }
        }
    }

    // No healthy warm route. Offer at most one half-open probe (plan 11.6);
    // deterministic pick so repeated admissions during one quarantine window
    // keep probing the same pair.
    if let Some(probe) = probe_candidates
        .iter()
        .min_by_key(|c| c.provider)
        .filter(|c| c.advisory_capacity_ok)
    {
        return AdmissionDecision::Prepare(permit_for(probe, traits, config, now, true));
    }

    // Nothing dispatchable: transient failures mean retry, otherwise reject.
    let transient = failures.keys().any(|f| f.is_transient()) || !probe_candidates.is_empty();
    if transient {
        let (reason, delay) = capacity_reason(&failures, !probe_candidates.is_empty(), config);
        AdmissionDecision::RetryAfter { reason, delay }
    } else {
        AdmissionDecision::Reject {
            reason: RejectionReason::AllGated { failures },
        }
    }
}

fn permit_for(
    candidate: &CandidateSnapshot,
    traits: &RequestTraits,
    config: &AdmissionConfig,
    now: TimestampMs,
    is_probe: bool,
) -> DispatchPermit {
    DispatchPermit {
        provider: candidate.provider,
        model: traits.model.clone(),
        expires_at: now.saturating_add(config.permit_ttl),
        permit_ttl: config.permit_ttl,
        is_probe,
        predicted_first_content: candidate
            .calibration
            .apply_to(candidate.predicted_first_content),
    }
}

/// Pick the dominant capacity story for the retry hint. Quarantine-only and
/// cold-model conditions get their own delays; everything else is generic
/// saturation.
fn capacity_reason(
    failures: &BTreeMap<GateFailure, u32>,
    probe_blocked: bool,
    config: &AdmissionConfig,
) -> (CapacityReason, DurationMs) {
    let count = |f: GateFailure| failures.get(&f).copied().unwrap_or(0);
    let saturation = count(GateFailure::PermitsExhausted)
        + count(GateFailure::DataLaneFull)
        + count(GateFailure::ControlLaneFull)
        + count(GateFailure::AdvisoryCapacity)
        + count(GateFailure::AlreadyAttempted)
        + count(GateFailure::NoCurrentSession);
    let quarantine = count(GateFailure::Quarantined) + count(GateFailure::ProbeOutstanding);
    let cold = count(GateFailure::ModelNotReady);

    if saturation > 0 {
        (CapacityReason::FleetSaturated, config.saturated_delay)
    } else if cold > 0 {
        (CapacityReason::ModelColdEverywhere, config.cold_model_delay)
    } else if quarantine > 0 || probe_blocked {
        (CapacityReason::QuarantinedOnly, config.quarantined_delay)
    } else {
        (CapacityReason::FleetSaturated, config.saturated_delay)
    }
}
