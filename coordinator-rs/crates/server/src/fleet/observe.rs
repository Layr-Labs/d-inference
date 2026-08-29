//! Reducers for trust verdicts, model lifecycle, heartbeats, health and
//! calibration observations, and the read-only snapshot (plan §9.1.6,
//! §10.7, §11.4, §11.6).

use std::collections::HashMap;

use darkbloom_core::fleet::calibration::CalibrationKey;
use darkbloom_core::fleet::health::{self, HealthEvent, HealthState, SecurityFence};
use darkbloom_core::fleet::model_presence::{ModelPresence, PresenceEvent, PresenceOutcome};
use darkbloom_core::ids::{
    HardwareClass, ModelId, ProviderId, SessionEpoch, StateRevision, TrustEpoch,
};
use darkbloom_core::provider_error::ProviderErrorClass;
use darkbloom_core::time::DurationMs;
use darkbloom_protocol::json_v2::ErrorClass;

use crate::contracts::{FleetObservation, FleetSnapshot, HeartbeatUpdate, TrustVerdict};

use super::state::{duration_to_ms, now_ms, FleetState};

/// Applies a trust verdict with monotonic trust-epoch fencing (plan §9.1.6):
/// only a strictly newer epoch mutates, so a hard downgrade can never be
/// reversed by an older in-flight verifier result.
pub(crate) fn handle_trust(
    state: &mut FleetState,
    provider: ProviderId,
    trust_epoch: TrustEpoch,
    verdict: TrustVerdict,
) {
    let Some(entry) = state.providers.get_mut(&provider) else {
        state.counters.stale_commands += 1;
        return;
    };
    if trust_epoch <= entry.trust.epoch {
        state.counters.trust_verdicts_fenced += 1;
        tracing::debug!(
            provider = %provider,
            stale = trust_epoch.get(),
            current = entry.trust.epoch.get(),
            "trust verdict fenced as stale"
        );
        return;
    }
    let stamped_at_ms = match &verdict {
        TrustVerdict::Untrusted { reason } => {
            tracing::warn!(provider = %provider, reason, "provider untrusted");
            None
        }
        _ => Some(now_ms().get()),
    };
    entry.trust = super::TrustState {
        epoch: trust_epoch,
        verdict,
        stamped_at_ms,
    };
    state.counters.trust_verdicts_applied += 1;
}

/// Reduces one versioned `model_ready` / `model_gone` event (plan §10.7),
/// fenced by both the session epoch and the state revision.
pub(crate) fn handle_lifecycle(
    state: &mut FleetState,
    provider: ProviderId,
    epoch: SessionEpoch,
    model: ModelId,
    ready: bool,
    revision: StateRevision,
) {
    let Some(entry) = state.providers.get_mut(&provider) else {
        state.counters.stale_commands += 1;
        return;
    };
    if epoch != entry.last_epoch || entry.session.is_none() {
        state.counters.stale_commands += 1;
        return;
    }
    let event = if ready {
        PresenceEvent::ModelReady { revision, model }
    } else {
        PresenceEvent::ModelGone { revision, model }
    };
    if entry.presence.apply(event) == PresenceOutcome::IgnoredStale {
        state.counters.heartbeats_stale += 1;
    }
}

/// Reduces one coalesced heartbeat: the full presence snapshot (revision
/// fenced) plus the advisory candidate refresh (plan §10.7, §11.3).
pub(crate) fn handle_heartbeat(state: &mut FleetState, update: HeartbeatUpdate) {
    let Some(entry) = state.providers.get_mut(&update.provider) else {
        state.counters.heartbeats_stale += 1;
        return;
    };
    if update.epoch != entry.last_epoch || entry.session.is_none() {
        state.counters.heartbeats_stale += 1;
        return;
    }
    let models = update
        .models
        .into_iter()
        .map(|(model, ready)| {
            let presence = if ready {
                ModelPresence::Ready
            } else {
                ModelPresence::Loading
            };
            (model, presence)
        })
        .collect();
    let outcome = entry.presence.apply(PresenceEvent::HeartbeatSnapshot {
        revision: update.revision,
        models,
    });
    if outcome == PresenceOutcome::IgnoredStale {
        state.counters.heartbeats_stale += 1;
        return;
    }
    entry.advisory = Some(super::state::AdvisoryState {
        candidate: update.candidate,
    });
    state.counters.heartbeats_applied += 1;
}

/// Reduces health/calibration observations (plan §11.4, §11.6): capacity
/// rejection is never a fault, `invalid_request` never touches health, and
/// security observations fence the whole machine.
pub(crate) fn handle_observe(state: &mut FleetState, observation: FleetObservation) {
    let now = now_ms();
    match observation {
        FleetObservation::PrepareRejected {
            provider,
            model,
            class,
        } => {
            if class == ErrorClass::Security {
                fence(state, provider);
                return;
            }
            let Some(entry) = state.providers.get_mut(&provider) else {
                return;
            };
            if class == ErrorClass::Capacity {
                // Invalidate advisory capacity until fresh state arrives.
                if let Some(advisory) = entry.advisory.as_mut() {
                    advisory.candidate.advisory_capacity_ok = false;
                }
            }
            apply_health(
                state,
                provider,
                &model,
                HealthEvent::ProviderError(map_error_class(class)),
            );
        }
        FleetObservation::ProviderFault { provider, model } => {
            let current = current_health(state, provider, &model);
            let event = if matches!(current, HealthState::HalfOpen) {
                HealthEvent::ProbeFailed
            } else {
                HealthEvent::ProviderError(ProviderErrorClass::Fault)
            };
            apply_health(state, provider, &model, event);
        }
        FleetObservation::FirstContent {
            provider,
            model,
            predicted,
            actual,
        } => {
            let current = current_health(state, provider, &model);
            let event = if matches!(current, HealthState::HalfOpen) {
                HealthEvent::ProbeSucceeded
            } else {
                HealthEvent::Success
            };
            apply_health(state, provider, &model, event);

            let hardware_class = state
                .providers
                .get(&provider)
                .and_then(|e| e.hardware_class.clone())
                .unwrap_or_else(|| HardwareClass::new("unknown"));
            state.calibration.observe(
                CalibrationKey {
                    model,
                    hardware_class,
                },
                DurationMs::new(duration_to_ms(actual)),
                DurationMs::new(duration_to_ms(predicted)),
                &state.tunables.calibration,
            );
        }
        FleetObservation::SecurityFence { provider } => fence(state, provider),
    }
    let _ = now;
}

/// Machine-wide security fence (plan §11.6): sticky; only an operator-level
/// action outside this actor lifts it.
fn fence(state: &mut FleetState, provider: ProviderId) {
    if let Some(entry) = state.providers.get_mut(&provider) {
        if !entry.security.is_fenced() {
            tracing::warn!(provider = %provider, "provider security-fenced machine-wide");
        }
        entry.security = SecurityFence::Fenced;
    }
}

fn current_health(state: &FleetState, provider: ProviderId, model: &ModelId) -> HealthState {
    state
        .providers
        .get(&provider)
        .and_then(|e| e.health.get(model).copied())
        .unwrap_or_default()
}

fn apply_health(state: &mut FleetState, provider: ProviderId, model: &ModelId, event: HealthEvent) {
    let now = now_ms();
    let Some(entry) = state.providers.get_mut(&provider) else {
        return;
    };
    let current = entry.health.get(model).copied().unwrap_or_default();
    match health::apply(current, event, now, &state.tunables.health) {
        Ok(next) => {
            if next != current {
                tracing::debug!(
                    provider = %provider,
                    model = %model,
                    from = ?current,
                    to = ?next,
                    "health transition"
                );
            }
            entry.health.insert(model.clone(), next);
        }
        Err(err) => {
            // Structurally invalid transitions are benign races (e.g. a
            // probe result after the pair already recovered): observable,
            // never state-mutating.
            tracing::debug!(provider = %provider, model = %model, %err, "health event ignored");
        }
    }
}

fn map_error_class(class: ErrorClass) -> ProviderErrorClass {
    match class {
        ErrorClass::InvalidRequest => ProviderErrorClass::InvalidRequest,
        ErrorClass::Capacity => ProviderErrorClass::Capacity,
        ErrorClass::ModelNotReady => ProviderErrorClass::ModelNotReady,
        ErrorClass::Draining => ProviderErrorClass::Draining,
        ErrorClass::Cancelled => ProviderErrorClass::Cancelled,
        ErrorClass::Fault => ProviderErrorClass::Fault,
        ErrorClass::Security => ProviderErrorClass::Security,
    }
}

/// Cheap copy of counters and warm-model tallies for stats endpoints.
pub(crate) fn snapshot(state: &FleetState) -> FleetSnapshot {
    let now = now_ms();
    let mut warm_by_model: HashMap<String, usize> = HashMap::new();
    let mut routable = 0usize;
    for entry in state.providers.values() {
        if entry.session.is_none() {
            continue;
        }
        if state.trust_ok(entry) && state.challenge_fresh(entry, now) && !entry.security.is_fenced()
        {
            routable += 1;
        }
        for model in entry.presence.ready_models() {
            *warm_by_model.entry(model.as_str().to_owned()).or_insert(0) += 1;
        }
    }
    FleetSnapshot {
        providers: state.providers.len(),
        routable,
        permits_outstanding: state.permits.total_outstanding(),
        warm_by_model,
    }
}
