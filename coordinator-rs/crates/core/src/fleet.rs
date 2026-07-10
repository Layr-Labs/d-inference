//! Pure FleetActor admission reducer (no I/O).
//!
//! Runtime actor mailbox lands in Milestone 3; this module is the decision core.

use crate::admission::{AdmissionDecision, CapacityReason, DispatchPermit, RejectionReason};
use crate::health::HealthMachine;
use crate::ids::AttemptId;
use std::collections::{HashMap, HashSet};
use std::time::Duration;

#[derive(Debug, Clone)]
pub struct ProviderSnapshot {
    pub provider_id: String,
    pub session_epoch: u64,
    pub trusted: bool,
    pub challenge_fresh: bool,
    pub encrypted_transport: bool,
    pub ready_models: HashSet<String>,
    pub health: HealthMachine,
    pub data_lane_full: bool,
    pub predicted_first_content_ms: f64,
    pub predicted_decode_ms: f64,
}

#[derive(Debug, Clone)]
pub struct AdmitRequest {
    pub model: String,
    pub attempt: AttemptId,
    pub exclude_providers: HashSet<String>,
    pub require_tools: bool,
    pub permit_ttl: Duration,
}

#[derive(Debug, Default)]
pub struct FleetState {
    pub providers: HashMap<String, ProviderSnapshot>,
}

impl FleetState {
    pub fn upsert(&mut self, snap: ProviderSnapshot) {
        self.providers.insert(snap.provider_id.clone(), snap);
    }

    /// One admission operation: hard gates → score → prepare permit.
    pub fn admit(&self, req: &AdmitRequest) -> AdmissionDecision {
        let mut candidates: Vec<&ProviderSnapshot> = self
            .providers
            .values()
            .filter(|p| !req.exclude_providers.contains(&p.provider_id))
            .filter(|p| p.trusted && p.challenge_fresh && p.encrypted_transport)
            .filter(|p| p.ready_models.contains(&req.model))
            .filter(|p| p.health.admits_general_traffic())
            .filter(|p| !p.data_lane_full)
            .collect();

        if candidates.is_empty() {
            // Distinguish quarantine-only vs no warm.
            let any_quarantined = self.providers.values().any(|p| {
                !req.exclude_providers.contains(&p.provider_id)
                    && p.ready_models.contains(&req.model)
                    && !p.health.admits_general_traffic()
            });
            if any_quarantined {
                return AdmissionDecision::Reject {
                    reason: RejectionReason::Quarantined,
                };
            }
            return AdmissionDecision::RetryAfter {
                reason: CapacityReason::NoWarmProvider,
                delay: Duration::from_secs(2),
            };
        }

        candidates.sort_by(|a, b| {
            let sa = a.predicted_first_content_ms + a.predicted_decode_ms;
            let sb = b.predicted_first_content_ms + b.predicted_decode_ms;
            sa.partial_cmp(&sb).unwrap_or(std::cmp::Ordering::Equal)
        });

        let best = candidates[0];
        AdmissionDecision::Prepare(DispatchPermit {
            attempt: req.attempt.clone(),
            provider_id: best.provider_id.clone(),
            model: req.model.clone(),
            expires_after: req.permit_ttl,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::health::HealthMachine;
    use std::time::Instant;

    fn base(id: &str, model: &str, ttft: f64) -> ProviderSnapshot {
        let mut ready = HashSet::new();
        ready.insert(model.to_string());
        ProviderSnapshot {
            provider_id: id.to_string(),
            session_epoch: 1,
            trusted: true,
            challenge_fresh: true,
            encrypted_transport: true,
            ready_models: ready,
            health: HealthMachine::healthy(),
            data_lane_full: false,
            predicted_first_content_ms: ttft,
            predicted_decode_ms: 100.0,
        }
    }

    #[test]
    fn picks_lowest_predicted_latency() {
        let mut fleet = FleetState::default();
        fleet.upsert(base("slow", "m", 500.0));
        fleet.upsert(base("fast", "m", 50.0));
        let decision = fleet.admit(&AdmitRequest {
            model: "m".into(),
            attempt: AttemptId::new("a1"),
            exclude_providers: HashSet::new(),
            require_tools: false,
            permit_ttl: Duration::from_secs(2),
        });
        match decision {
            AdmissionDecision::Prepare(p) => assert_eq!(p.provider_id, "fast"),
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn excludes_attempted_providers() {
        let mut fleet = FleetState::default();
        fleet.upsert(base("a", "m", 10.0));
        fleet.upsert(base("b", "m", 20.0));
        let mut exclude = HashSet::new();
        exclude.insert("a".into());
        let decision = fleet.admit(&AdmitRequest {
            model: "m".into(),
            attempt: AttemptId::new("a2"),
            exclude_providers: exclude,
            require_tools: false,
            permit_ttl: Duration::from_secs(2),
        });
        match decision {
            AdmissionDecision::Prepare(p) => assert_eq!(p.provider_id, "b"),
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn rejects_quarantined_only_fleet() {
        let mut fleet = FleetState::default();
        let mut p = base("q", "m", 10.0);
        p.health.on_fault(Instant::now(), Duration::from_secs(60));
        p.health.on_fault(Instant::now(), Duration::from_secs(60));
        fleet.upsert(p);
        let decision = fleet.admit(&AdmitRequest {
            model: "m".into(),
            attempt: AttemptId::new("a"),
            exclude_providers: HashSet::new(),
            require_tools: false,
            permit_ttl: Duration::from_secs(2),
        });
        assert!(matches!(
            decision,
            AdmissionDecision::Reject {
                reason: RejectionReason::Quarantined
            }
        ));
    }
}
