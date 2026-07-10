//! The composed admission operation: gate, filter, score, and decide.

use std::collections::{BTreeMap, BTreeSet};

use super::candidate::{CandidateSnapshot, RequestTraits};
use super::decision::{
    AdmissionConfig, AdmissionDecision, CapacityReason, DispatchPermit, RejectionReason,
};
use super::gates::{gate, GateFailure};
use crate::fleet::health::HealthState;
use crate::fleet::scoring::{score, select_best, Score, ScoreInputs};
use crate::ids::ProviderId;
use crate::time::{DurationMs, TimestampMs};

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
