//! The one admission operation (plan §11.1): candidate assembly, the pure
//! core decision, and permit-reservation execution.
//!
//! The actor assembles the candidate list from live sessions
//! ([`super::candidates`]), calls the pure
//! `darkbloom_core::fleet::admission::admit`, then executes the described
//! permit reservation in the `PermitBook`. Authoritative inputs (session
//! liveness, trust, presence, lane headroom, permit counts, calibration) are
//! read here at admission time; only capacity estimates come from the stored
//! advisory heartbeat snapshot (plan §11.3: advisory ranks, never
//! authorizes).

use std::collections::BTreeSet;
use std::time::Duration;

use tokio::sync::oneshot;

use darkbloom_core::fleet::admission::{
    admit, AdmissionDecision, CandidateSnapshot, CapacityReason, RequestTraits,
};
use darkbloom_core::fleet::health::{self, HealthEvent};
use darkbloom_core::ids::{JobId, ModelId, ProviderId};
use darkbloom_core::time::TimestampMs;

use crate::contracts::{AdmitGrant, AdmitOutcome, AdmitRequest, PriceCard};

use super::candidates::build_candidate;
use super::permits::{permit_id_for, release_inner};
use super::state::{now_ms, FleetState};
use super::PermitMeta;

pub(crate) fn handle_admit(
    state: &mut FleetState,
    req: AdmitRequest,
    reply: oneshot::Sender<AdmitOutcome>,
) {
    let now = now_ms();
    state.admit_seq = state.admit_seq.wrapping_add(1);

    // Alias resolution against the atomically swapped catalog snapshot.
    let catalog = state.catalog.load();
    let concrete_str = catalog
        .aliases
        .get(req.model.as_str())
        .cloned()
        .unwrap_or_else(|| req.model.as_str().to_owned());
    let price = catalog
        .prices
        .get(&concrete_str)
        .copied()
        .unwrap_or(PriceCard::ZERO);
    let concrete_model = ModelId::new(concrete_str);

    let traits = RequestTraits {
        model: concrete_model.clone(),
        needs_vision: req.traits.needs_vision,
        needs_tools: req.traits.needs_tools,
        needs_media: req.traits.needs_media,
        paid: req.paid,
        expected_output_tokens: req.traits.expected_output_tokens,
    };
    let exclude: BTreeSet<ProviderId> = req.exclude.iter().copied().collect();

    let candidates: Vec<CandidateSnapshot> = state
        .providers
        .iter()
        .filter_map(|(id, entry)| build_candidate(state, *id, entry, &concrete_model, now))
        .collect();

    let seed = tiebreak_seed(req.job, state.admit_seq);
    let decision = admit(&traits, &candidates, &exclude, &state.admission, now, seed);

    let outcome = match decision {
        AdmissionDecision::Prepare(permit) => {
            state.counters.admits_granted += 1;
            grant(state, &req, permit, &candidates, concrete_model, price, now)
        }
        AdmissionDecision::RetryAfter { reason, delay } => {
            state.counters.admits_retry += 1;
            if tracing::enabled!(tracing::Level::DEBUG) {
                for c in &candidates {
                    tracing::debug!(
                        job = %req.job,
                        provider = %c.provider,
                        presence = ?c.model_presence,
                        advisory_ok = c.advisory_capacity_ok,
                        permits = c.outstanding_permits,
                        max_permits = c.max_outstanding_permits,
                        data_lane = c.data_lane_headroom,
                        control_lane = c.control_lane_headroom,
                        trusted = c.trusted,
                        fresh = c.challenge_fresh,
                        beneficiary = c.beneficiary.is_some(),
                        health = ?c.health,
                        security = ?c.security,
                        integrity = c.runtime_integrity,
                        tools = c.supports_tools,
                        vision = c.supports_vision,
                        needs_tools = traits.needs_tools,
                        needs_vision = traits.needs_vision,
                        paid = traits.paid,
                        "admission retry candidate"
                    );
                }
            }
            AdmitOutcome::RetryAfter {
                reason: capacity_reason_str(reason).to_owned(),
                delay: Duration::from_millis(delay.get()),
            }
        }
        AdmissionDecision::Reject { reason } => {
            state.counters.admits_rejected += 1;
            AdmitOutcome::Reject(reason)
        }
    };

    // The requester can vanish between try_send and reply: a granted
    // permit must not leak (plan §9.2.10 idempotent release path).
    if let Err(AdmitOutcome::Grant(grant)) = reply.send(outcome) {
        release_inner(state, grant.permit_id);
    }
}

/// Executes the permit reservation the pure decision described and builds
/// the grant.
fn grant(
    state: &mut FleetState,
    req: &AdmitRequest,
    permit: darkbloom_core::fleet::admission::DispatchPermit,
    candidates: &[CandidateSnapshot],
    concrete_model: ModelId,
    price: PriceCard,
    now: TimestampMs,
) -> AdmitOutcome {
    let provider = permit.provider;
    let max_outstanding = candidates
        .iter()
        .find(|c| c.provider == provider)
        .map_or(state.tunables.default_max_outstanding_permits, |c| {
            c.max_outstanding_permits
        });

    let permit_id = permit_id_for(req.job, provider);
    if state
        .permits
        .reserve(permit_id, provider, now, permit.permit_ttl, max_outstanding)
        .is_err()
    {
        // Unreachable in the single-threaded actor (the gate already checked
        // the bound), but a typed fallback beats a panic: shed as saturation.
        return AdmitOutcome::RetryAfter {
            reason: capacity_reason_str(CapacityReason::FleetSaturated).to_owned(),
            delay: Duration::from_millis(state.admission.saturated_delay.get()),
        };
    }
    state.permit_meta.insert(
        permit_id,
        PermitMeta {
            provider,
            model: concrete_model.clone(),
            is_probe: permit.is_probe,
        },
    );

    let Some(entry) = state.providers.get_mut(&provider) else {
        // Cannot happen: the candidate came from this map. Fail closed.
        release_inner(state, permit_id);
        return AdmitOutcome::RetryAfter {
            reason: capacity_reason_str(CapacityReason::FleetSaturated).to_owned(),
            delay: Duration::from_millis(state.admission.saturated_delay.get()),
        };
    };
    if permit.is_probe {
        let current = entry
            .health
            .get(&concrete_model)
            .copied()
            .unwrap_or_default();
        match health::apply(
            current,
            HealthEvent::ProbeDispatched,
            now,
            &state.tunables.health,
        ) {
            Ok(next) => {
                entry.health.insert(concrete_model.clone(), next);
            }
            Err(err) => {
                tracing::warn!(provider = %provider, model = %concrete_model, %err,
                    "probe dispatch transition rejected");
            }
        }
    }
    let Some(session) = entry.session.clone() else {
        release_inner(state, permit_id);
        return AdmitOutcome::RetryAfter {
            reason: capacity_reason_str(CapacityReason::FleetSaturated).to_owned(),
            delay: Duration::from_millis(state.admission.saturated_delay.get()),
        };
    };
    let beneficiary = entry.registration.as_ref().and_then(|r| r.beneficiary);
    // Frozen at grant time from the registration that owns this session:
    // the request task encrypts to exactly the key this epoch registered.
    let provider_public_key_b64 = entry
        .registration
        .as_ref()
        .map(|r| r.public_key_b64.clone())
        .unwrap_or_default();
    let predicted = Duration::from_millis(permit.predicted_first_content.get());

    AdmitOutcome::Grant(Box::new(AdmitGrant {
        permit,
        permit_id,
        provider,
        session,
        provider_public_key_b64,
        concrete_model,
        price,
        beneficiary,
        predicted_first_content: predicted,
    }))
}

fn capacity_reason_str(reason: CapacityReason) -> &'static str {
    match reason {
        CapacityReason::ModelColdEverywhere => "model_cold_everywhere",
        CapacityReason::FleetSaturated => "fleet_saturated",
        CapacityReason::QuarantinedOnly => "quarantined_only",
    }
}

/// Pure tiebreak seed: job identity spread by the admission sequence so one
/// job's alternate does not repeat the primary's near-tie pick.
fn tiebreak_seed(job: JobId, seq: u64) -> u64 {
    let bytes = job.as_bytes();
    let mut prefix = [0u8; 8];
    prefix.copy_from_slice(&bytes[..8]);
    u64::from_le_bytes(prefix) ^ seq.rotate_left(17)
}
