//! Candidate assembly: one [`CandidateSnapshot`] per live provider from
//! authoritative session state plus the advisory heartbeat snapshot
//! (plan §11.2, §11.3 — advisory ranks, never authorizes).

use darkbloom_core::fleet::admission::CandidateSnapshot;
use darkbloom_core::fleet::calibration::CalibrationKey;
use darkbloom_core::fleet::model_presence::ModelPresence;
use darkbloom_core::ids::{HardwareClass, ModelId, ProviderId};
use darkbloom_core::time::{DurationMs, TimestampMs};

use super::state::FleetState;
use super::ProviderEntry;

/// One candidate assembled from authoritative live state plus the advisory
/// heartbeat snapshot (plan §11.2, §11.3). `None` when the provider has no
/// current session (stored records never create routing capacity, plan §8).
pub(super) fn build_candidate(
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
