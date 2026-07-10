//! Fleet-side permit identity: minting (the single authority) and the
//! idempotent release path (plan §9.2.10).
//! Invariant: permits are minted here and only echoed back — double release
//! is a visible no-op and can never orphan a live permit.

use sha2::{Digest, Sha256};

use darkbloom_core::fleet::health::{self, HealthEvent, HealthState};
use darkbloom_core::ids::{JobId, PermitId, ProviderId};

use super::state::{now_ms, FleetState};

/// Mints the [`PermitId`] for one (job, provider) admission.
///
/// This is the SINGLE permit-identity authority: the fleet mints the id
/// here and carries it on [`crate::contracts::AdmitGrant::permit_id`]; the
/// request task ECHOES that id back in `FleetCommand::ReleasePermit` and
/// never re-derives it. The derivation is deterministic (SHA-256 over the
/// job and provider UUID bytes, truncated to 16 bytes) — unique per permit
/// because a job never admits the same provider twice (the exclusion set
/// forbids re-selection).
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
pub(super) fn release_inner(state: &mut FleetState, permit: PermitId) -> bool {
    state.permit_meta.remove(&permit);
    matches!(
        state.permits.release(permit),
        darkbloom_core::fleet::permits::ReleaseOutcome::Released
    )
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
