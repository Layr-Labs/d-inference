//! The one admission operation (plan §11.1) plus idempotent permit release.
//!
//! The actor assembles the candidate list from live sessions, calls the pure
//! `darkbloom_core::fleet::admission::admit`, then executes the described
//! permit reservation in the [`PermitBook`]. Authoritative inputs (session
//! liveness, trust, presence, lane headroom, permit counts, calibration) are
//! read here at admission time; only capacity estimates come from the stored
//! advisory heartbeat snapshot (plan §11.3: advisory ranks, never
//! authorizes).

use std::collections::BTreeSet;
use std::time::Duration;

use sha2::{Digest, Sha256};
use tokio::sync::oneshot;

use darkbloom_core::fleet::admission::{
    admit, AdmissionDecision, CandidateSnapshot, CapacityReason, RequestTraits,
};
use darkbloom_core::fleet::calibration::CalibrationKey;
use darkbloom_core::fleet::health::{self, HealthEvent, HealthState};
use darkbloom_core::fleet::model_presence::ModelPresence;
#[allow(unused_imports)] // doc link
use darkbloom_core::fleet::permits::PermitBook;
use darkbloom_core::ids::{HardwareClass, JobId, ModelId, PermitId, ProviderId};
use darkbloom_core::money::MicroUsd;
use darkbloom_core::time::{DurationMs, TimestampMs};

use crate::contracts::{AdmitGrant, AdmitOutcome, AdmitRequest, PriceCard};

use super::state::{now_ms, FleetState};
use super::{PermitMeta, ProviderEntry};

/// Derives the [`PermitId`] for one (job, provider) admission.
///
/// The frozen [`crate::contracts::AdmitGrant`] has no permit-id field, so
/// the fleet and the request task derive the same id deterministically:
/// SHA-256 over the job and provider UUID bytes, truncated to 16 bytes. A
/// job never admits the same provider twice (the exclusion set forbids
/// re-selection), so the pair uniquely names one permit.
#[must_use]
pub fn permit_id_for(job: JobId, provider: ProviderId) -> PermitId {
    let mut hasher = Sha256::new();
    hasher.update(b"darkbloom.permit.v1");
    hasher.update(job.as_bytes());
    hasher.update(provider.as_bytes());
    let digest = hasher.finalize();
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    PermitId::new(uuid::Uuid::from_bytes(bytes))
}

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
        .unwrap_or(PriceCard {
            prompt_micro_per_token: MicroUsd::ZERO,
            completion_micro_per_token: MicroUsd::ZERO,
        });
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
        release_inner(state, permit_id_for(req.job, grant.provider));
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
    state.hedge.on_admission();

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
    let predicted = Duration::from_millis(permit.predicted_first_content.get());

    AdmitOutcome::Grant(Box::new(AdmitGrant {
        permit,
        provider,
        session,
        concrete_model,
        price,
        beneficiary,
        predicted_first_content: predicted,
    }))
}

/// Idempotent release (plan §9.2.10): double release is a visible no-op.
///
/// Releasing a *probe* permit whose pair is still `HalfOpen` counts as a
/// failed probe: a successful probe reports `Observe(FirstContent)` before
/// releasing, which resolves the machine first. Without this, an abandoned
/// probe would pin the pair in `HalfOpen` forever (its permit is out of the
/// book, so the expiry sweep can no longer see it).
pub(crate) fn handle_release(state: &mut FleetState, provider: ProviderId, permit: PermitId) {
    let meta = state.permit_meta.get(&permit).cloned();
    if let Some(meta) = &meta {
        if meta.provider != provider {
            tracing::warn!(
                permit = %permit,
                claimed = %provider,
                actual = %meta.provider,
                "permit release provider mismatch"
            );
        }
    }
    let released = release_inner(state, permit);
    if !released {
        return;
    }
    let Some(meta) = meta else { return };
    if !meta.is_probe {
        return;
    }
    let now = now_ms();
    if let Some(entry) = state.providers.get_mut(&meta.provider) {
        let current = entry.health.get(&meta.model).copied().unwrap_or_default();
        if matches!(current, HealthState::HalfOpen) {
            if let Ok(next) = health::apply(
                current,
                HealthEvent::ProbeFailed,
                now,
                &state.tunables.health,
            ) {
                entry.health.insert(meta.model, next);
            }
        }
    }
}

/// Book release plus metadata cleanup; true when the permit was outstanding.
fn release_inner(state: &mut FleetState, permit: PermitId) -> bool {
    state.permit_meta.remove(&permit);
    matches!(
        state.permits.release(permit),
        darkbloom_core::fleet::permits::ReleaseOutcome::Released
    )
}

/// One candidate assembled from authoritative live state plus the advisory
/// heartbeat snapshot (plan §11.2, §11.3). `None` when the provider has no
/// current session (stored records never create routing capacity, plan §8).
fn build_candidate(
    state: &FleetState,
    provider: ProviderId,
    entry: &ProviderEntry,
    model: &ModelId,
    now: TimestampMs,
) -> Option<CandidateSnapshot> {
    let session = entry.session.as_ref()?;
    let advisory = entry.advisory.as_ref().map(|a| &a.candidate);

    let presence: ModelPresence = entry.presence.presence(model);
    let health = entry.health.get(model).copied().unwrap_or_default();
    let calibration_key = CalibrationKey {
        model: model.clone(),
        hardware_class: entry
            .hardware_class
            .clone()
            .unwrap_or_else(|| HardwareClass::new("unknown")),
    };

    Some(CandidateSnapshot {
        provider,
        session_current: true,
        trusted: state.trust_ok(entry),
        challenge_fresh: state.challenge_fresh(entry, now),
        // Pilot scope: no runtime-manifest verification pillar yet; the
        // machine-wide security fence is the only integrity downgrade.
        runtime_integrity: !entry.security.is_fenced(),
        model_presence: presence,
        supports_vision: advisory.map_or_else(
            || has_capability(entry, super::state::SUPPORTS_VISION_CAPABILITY),
            |c| c.supports_vision,
        ),
        supports_tools: advisory.map_or_else(
            || has_capability(entry, super::state::SUPPORTS_TOOLS_CAPABILITY),
            |c| c.supports_tools,
        ),
        supports_media: advisory.map_or_else(
            || has_capability(entry, super::state::SUPPORTS_MEDIA_CAPABILITY),
            |c| c.supports_media,
        ),
        beneficiary: entry.registration.as_ref().and_then(|r| r.beneficiary),
        health,
        security: entry.security,
        data_lane_headroom: session.data_lane_has_headroom(),
        control_lane_headroom: session.control_lane_has_headroom(),
        outstanding_permits: state.permits.outstanding_for(provider),
        max_outstanding_permits: advisory
            .map_or(state.tunables.default_max_outstanding_permits, |c| {
                c.max_outstanding_permits
            }),
        // Advisory capacity fails open before the first heartbeat only for
        // presence sources other than heartbeats (v2 lifecycle events); the
        // prepared lease is the exact capacity authority (plan §11.3).
        advisory_capacity_ok: advisory.is_none_or(|c| c.advisory_capacity_ok),
        predicted_first_content: advisory.map_or(
            DurationMs::new(state.tunables.default_predicted_first_content_ms),
            |c| c.predicted_first_content,
        ),
        decode_tokens_per_sec: advisory.map_or(0, |c| c.decode_tokens_per_sec),
        calibration: state
            .calibration
            .correction(&calibration_key, &state.tunables.calibration),
    })
}

fn has_capability(entry: &ProviderEntry, capability: &str) -> bool {
    entry
        .registration
        .as_ref()
        .is_some_and(|r| r.capabilities.iter().any(|c| c == capability))
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn permit_id_is_deterministic_and_pair_unique() {
        let job_a = JobId::new(uuid::Uuid::from_u128(1));
        let job_b = JobId::new(uuid::Uuid::from_u128(2));
        let prov_a = ProviderId::new(uuid::Uuid::from_u128(10));
        let prov_b = ProviderId::new(uuid::Uuid::from_u128(11));

        assert_eq!(permit_id_for(job_a, prov_a), permit_id_for(job_a, prov_a));
        assert_ne!(permit_id_for(job_a, prov_a), permit_id_for(job_a, prov_b));
        assert_ne!(permit_id_for(job_a, prov_a), permit_id_for(job_b, prov_a));
    }
}
