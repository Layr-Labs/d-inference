//! v1 heartbeat → advisory [`CandidateSnapshot`] mapping (plan §11.3).
//!
//! Semantics ported from the Go heartbeat path (`registry.Heartbeat` +
//! scheduler reads): **`BackendCapacity.Slots` is authoritative when
//! present**; `warm_models` is only the legacy fallback. Slot state maps to
//! presence as:
//!
//! | slot state            | presence  | note                              |
//! |-----------------------|-----------|-----------------------------------|
//! | `running`             | Ready     | actively decoding                 |
//! | `idle`                | Ready     | **loaded** — never "unknown"      |
//! | `reloading`           | Loading   | not routable yet                  |
//! | `crashed`             | (absent)  | not present                       |
//! | `idle_shutdown`       | (absent)  | released after idle timeout       |
//!
//! Field mapping chosen for the pilot (the advisory candidate is ranking
//! input only; the prepared lease is the exact authority — plan §11.3):
//!
//! - `decode_tokens_per_sec`: max per-slot `observed_decode_tps`, clamped
//!   to the Go plausibility ceiling (10 000).
//! - `predicted_first_content`: `400 ms + 900 ms × Σ num_waiting + 150 ms ×
//!   Σ num_running` — a queue-depth occupancy estimate (v1 providers report
//!   no first-content ETA).
//! - `advisory_capacity_ok`: false when any slot reports
//!   `wedge_suspected`, when memory pressure > 0.95, or when every
//!   budget-reporting slot is at its token budget.
//! - `max_outstanding_permits`: Σ per-slot free concurrency
//!   (`max_concurrency − num_running − num_waiting`, ≥ 0; slots without a
//!   reported bound contribute 1), clamped to [1, 8]; 2 when no slots.
//! - Authoritative fields (trust, freshness, lanes, permits, calibration,
//!   presence) are placeholders here — the fleet overwrites them from live
//!   state at admission (`fleet::candidates::build_candidate`).

use darkbloom_core::fleet::admission::CandidateSnapshot;
use darkbloom_core::fleet::calibration::RatioPerMille;
use darkbloom_core::fleet::health::{HealthState, SecurityFence};
use darkbloom_core::fleet::model_presence::ModelPresence;
use darkbloom_core::ids::{ModelId, ProviderId, SessionEpoch, StateRevision};
use darkbloom_core::time::DurationMs;
use darkbloom_protocol::json_v1::HeartbeatMessage;

use crate::contracts::HeartbeatUpdate;

/// Sanity ceiling on advisory decode TPS (Go `maxPlausibleDecodeTPS`).
const MAX_PLAUSIBLE_DECODE_TPS: f64 = 10_000.0;

/// Per-provider request-shape support derived once at registration.
#[derive(Debug, Clone, Copy)]
pub(crate) struct ProviderStatics {
    pub supports_vision: bool,
    pub supports_tools: bool,
    pub supports_media: bool,
}

/// Maps one v1 heartbeat into the coalesced fleet update. `revision` is the
/// session-local monotonic counter (one revision domain per session — the
/// fleet resets presence on reconnect, plan §10.7).
pub(crate) fn map_heartbeat(
    provider: ProviderId,
    epoch: SessionEpoch,
    revision: StateRevision,
    statics: ProviderStatics,
    msg: &HeartbeatMessage,
) -> HeartbeatUpdate {
    let slots: &[darkbloom_protocol::json_v1::BackendSlotCapacity] = msg
        .backend_capacity
        .as_ref()
        .and_then(|c| c.slots.as_deref())
        .unwrap_or(&[]);

    let models: Vec<(ModelId, bool)> = if msg.backend_capacity.is_some() {
        slots
            .iter()
            .filter_map(|slot| match slot.state.as_str() {
                "running" | "idle" => Some((ModelId::new(slot.model.clone()), true)),
                "reloading" => Some((ModelId::new(slot.model.clone()), false)),
                _ => None, // crashed / idle_shutdown / unknown: not present
            })
            .collect()
    } else {
        // Legacy fallback: providers without BackendCapacity report loaded
        // models via warm_models only.
        msg.warm_models
            .iter()
            .map(|m| (ModelId::new(m.clone()), true))
            .collect()
    };

    let decode_tps = slots
        .iter()
        .map(|s| s.observed_decode_tps.clamp(0.0, MAX_PLAUSIBLE_DECODE_TPS))
        .fold(0.0_f64, f64::max);

    let total_waiting: u64 = slots.iter().map(|s| s.num_waiting.max(0) as u64).sum();
    let total_running: u64 = slots.iter().map(|s| s.num_running.max(0) as u64).sum();
    let predicted_ms = 400_u64
        .saturating_add(total_waiting.saturating_mul(900))
        .saturating_add(total_running.saturating_mul(150));

    let wedge = slots.iter().any(|s| s.wedge_suspected);
    let memory_ok = msg.system_metrics.memory_pressure <= 0.95;
    let budget_slots = slots.iter().filter(|s| s.active_token_budget_max > 0);
    let budget_exhausted = {
        let mut any = false;
        let mut all_full = true;
        for slot in budget_slots {
            any = true;
            if slot.active_token_budget_used < slot.active_token_budget_max {
                all_full = false;
            }
        }
        any && all_full
    };
    let advisory_capacity_ok = !wedge && memory_ok && !budget_exhausted;

    let max_outstanding: u32 = if slots.is_empty() {
        2
    } else {
        let free: i64 = slots
            .iter()
            .map(|s| {
                if s.max_concurrency > 0 {
                    (s.max_concurrency - s.num_running - s.num_waiting).max(0)
                } else {
                    1
                }
            })
            .sum();
        u32::try_from(free).unwrap_or(0).clamp(1, 8)
    };

    let candidate = CandidateSnapshot {
        provider,
        // Placeholders below (session_current .. calibration) are overwritten
        // by the fleet from authoritative live state at admission time.
        session_current: true,
        trusted: true,
        challenge_fresh: true,
        runtime_integrity: true,
        model_presence: ModelPresence::NotPresent,
        supports_vision: statics.supports_vision,
        supports_tools: statics.supports_tools,
        supports_media: statics.supports_media,
        beneficiary: None,
        health: HealthState::Healthy,
        security: SecurityFence::Clear,
        data_lane_headroom: true,
        control_lane_headroom: true,
        outstanding_permits: 0,
        max_outstanding_permits: max_outstanding,
        advisory_capacity_ok,
        predicted_first_content: DurationMs::new(predicted_ms),
        decode_tokens_per_sec: decode_tps as u32,
        calibration: RatioPerMille::UNIT,
    };

    HeartbeatUpdate {
        provider,
        epoch,
        revision,
        candidate,
        models,
    }
}

#[cfg(test)]
mod tests {
    use darkbloom_protocol::json_v1::{BackendCapacity, BackendSlotCapacity};
    use uuid::Uuid;

    use super::*;

    fn statics() -> ProviderStatics {
        ProviderStatics {
            supports_vision: false,
            supports_tools: true,
            supports_media: false,
        }
    }

    fn slot(model: &str, state: &str) -> BackendSlotCapacity {
        BackendSlotCapacity {
            model: model.to_owned(),
            state: state.to_owned(),
            ..Default::default()
        }
    }

    fn map(msg: &HeartbeatMessage) -> HeartbeatUpdate {
        map_heartbeat(
            ProviderId::new(Uuid::from_u128(1)),
            SessionEpoch::new(1),
            StateRevision::new(1),
            statics(),
            msg,
        )
    }

    #[test]
    fn slots_are_authoritative_and_idle_means_loaded() {
        let msg = HeartbeatMessage {
            warm_models: vec!["stale-warm".to_owned()],
            backend_capacity: Some(BackendCapacity {
                slots: Some(vec![
                    slot("qwen", "idle"),
                    slot("gemma", "running"),
                    slot("phi", "reloading"),
                    slot("dead", "crashed"),
                    slot("gone", "idle_shutdown"),
                ]),
                ..Default::default()
            }),
            ..Default::default()
        };
        let update = map(&msg);
        let ready: Vec<(String, bool)> = update
            .models
            .iter()
            .map(|(m, r)| (m.as_str().to_owned(), *r))
            .collect();
        assert!(ready.contains(&("qwen".to_owned(), true)), "idle is loaded");
        assert!(ready.contains(&("gemma".to_owned(), true)));
        assert!(
            ready.contains(&("phi".to_owned(), false)),
            "reloading = loading"
        );
        assert!(!ready.iter().any(|(m, _)| m == "dead" || m == "gone"));
        assert!(
            !ready.iter().any(|(m, _)| m == "stale-warm"),
            "warm_models ignored when slots present"
        );
    }

    #[test]
    fn warm_models_fallback_without_capacity() {
        let msg = HeartbeatMessage {
            warm_models: vec!["qwen".to_owned()],
            ..Default::default()
        };
        let update = map(&msg);
        assert_eq!(update.models.len(), 1);
        assert!(update.models[0].1);
    }

    #[test]
    fn occupancy_and_capacity_signals() {
        let mut busy = slot("qwen", "running");
        busy.num_running = 2;
        busy.num_waiting = 3;
        busy.observed_decode_tps = 55.5;
        busy.max_concurrency = 8;
        let msg = HeartbeatMessage {
            backend_capacity: Some(BackendCapacity {
                slots: Some(vec![busy]),
                ..Default::default()
            }),
            ..Default::default()
        };
        let update = map(&msg);
        let c = &update.candidate;
        assert_eq!(
            c.predicted_first_content,
            DurationMs::new(400 + 3 * 900 + 2 * 150)
        );
        assert_eq!(c.decode_tokens_per_sec, 55);
        assert_eq!(c.max_outstanding_permits, 3); // 8 - 2 - 3
        assert!(c.advisory_capacity_ok);
    }

    #[test]
    fn wedge_and_budget_exhaustion_invalidate_advisory() {
        let mut wedged = slot("qwen", "running");
        wedged.wedge_suspected = true;
        let msg = HeartbeatMessage {
            backend_capacity: Some(BackendCapacity {
                slots: Some(vec![wedged]),
                ..Default::default()
            }),
            ..Default::default()
        };
        assert!(!map(&msg).candidate.advisory_capacity_ok);

        let mut full = slot("qwen", "running");
        full.active_token_budget_max = 1000;
        full.active_token_budget_used = 1000;
        let msg = HeartbeatMessage {
            backend_capacity: Some(BackendCapacity {
                slots: Some(vec![full]),
                ..Default::default()
            }),
            ..Default::default()
        };
        assert!(!map(&msg).candidate.advisory_capacity_ok);
    }
}
