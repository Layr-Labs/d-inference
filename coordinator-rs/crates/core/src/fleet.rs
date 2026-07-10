//! Pure FleetActor admission reducer (no I/O).
//!
//! Runtime actor mailbox lands in Milestone 3; this module is the decision core.

use crate::admission::{AdmissionDecision, CapacityReason, DispatchPermit, RejectionReason};
use crate::calibration::TtftCalibrator;
use crate::health::HealthMachine;
use crate::ids::AttemptId;
use crate::trust::TrustState;
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
    pub trust: TrustState,
}

#[derive(Debug, Clone)]
pub struct AdmitRequest {
    pub model: String,
    pub attempt: AttemptId,
    pub exclude_providers: HashSet<String>,
    pub require_tools: bool,
    pub permit_ttl: Duration,
}

#[derive(Debug, Default, Clone)]
pub struct FleetState {
    pub providers: HashMap<String, ProviderSnapshot>,
    pub calibrator: TtftCalibrator,
    /// provider_id -> last applied model-lifecycle state_revision
    pub model_revisions: HashMap<String, u64>,
}

impl FleetState {
    pub fn upsert(&mut self, snap: ProviderSnapshot) {
        self.providers.insert(snap.provider_id.clone(), snap);
    }

    pub fn record_ttft_sample(&mut self, model_id: &str, predicted_ms: f64, actual_ms: f64) {
        self.calibrator.record(model_id, predicted_ms, actual_ms);
    }

    /// Apply versioned `model_ready`. Ignores older revisions for this provider.
    pub fn apply_model_ready(
        &mut self,
        provider_id: &str,
        model: &str,
        state_revision: u64,
    ) -> bool {
        let last = self.model_revisions.get(provider_id).copied().unwrap_or(0);
        if state_revision < last {
            return false;
        }
        self.model_revisions
            .insert(provider_id.to_string(), state_revision);
        if let Some(p) = self.providers.get_mut(provider_id) {
            p.ready_models.insert(model.to_string());
            return true;
        }
        false
    }

    /// Apply versioned `model_gone`. Ignores older revisions for this provider.
    pub fn apply_model_gone(
        &mut self,
        provider_id: &str,
        model: &str,
        state_revision: u64,
    ) -> bool {
        let last = self.model_revisions.get(provider_id).copied().unwrap_or(0);
        if state_revision < last {
            return false;
        }
        self.model_revisions
            .insert(provider_id.to_string(), state_revision);
        if let Some(p) = self.providers.get_mut(provider_id) {
            p.ready_models.remove(model);
            return true;
        }
        false
    }

    /// One admission operation: hard gates → calibrated score → prepare permit.
    pub fn admit(&self, req: &AdmitRequest) -> AdmissionDecision {
        let mut candidates: Vec<&ProviderSnapshot> = self
            .providers
            .values()
            .filter(|p| !req.exclude_providers.contains(&p.provider_id))
            .filter(|p| {
                if p.trust.trust_epoch.0 > 0 {
                    p.trust.publicly_routable()
                } else {
                    p.trusted && p.challenge_fresh && p.encrypted_transport
                }
            })
            .filter(|p| p.ready_models.contains(&req.model))
            .filter(|p| p.health.admits_general_traffic())
            .filter(|p| !p.data_lane_full)
            .collect();

        if candidates.is_empty() {
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

        let corr = self.calibrator.correction(&req.model);
        candidates.sort_by(|a, b| {
            let sa = a.predicted_first_content_ms * corr + a.predicted_decode_ms;
            let sb = b.predicted_first_content_ms * corr + b.predicted_decode_ms;
            sa.partial_cmp(&sb).unwrap_or(std::cmp::Ordering::Equal)
        });
        // Fix Equal via python after write

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
            trust: crate::trust::TrustState::default(),
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

    #[test]
    fn calibration_scales_predictions_uniformly() {
        let mut fleet = FleetState::default();
        fleet.upsert(base("a", "m", 100.0));
        fleet.upsert(base("b", "m", 120.0));
        for _ in 0..20 {
            fleet.record_ttft_sample("m", 100.0, 200.0);
        }
        assert!((fleet.calibrator.correction("m") - 2.0).abs() < 1e-9);
        // Uniform model correction preserves relative order among same-model candidates.
        let decision = fleet.admit(&AdmitRequest {
            model: "m".into(),
            attempt: AttemptId::new("a3"),
            exclude_providers: HashSet::new(),
            require_tools: false,
            permit_ttl: Duration::from_secs(2),
        });
        match decision {
            AdmissionDecision::Prepare(p) => assert_eq!(p.provider_id, "a"),
            other => panic!("unexpected {other:?}"),
        }
        assert!((fleet.calibrator.calibrate("m", 50.0) - 100.0).abs() < 1e-9);
    }

    #[test]
    fn model_gone_ignores_stale_revision() {
        let mut fleet = FleetState::default();
        fleet.upsert(base("p", "m", 10.0));
        assert!(fleet.apply_model_ready("p", "m2", 5));
        assert!(fleet.providers["p"].ready_models.contains("m2"));
        assert!(!fleet.apply_model_gone("p", "m2", 4)); // stale
        assert!(fleet.providers["p"].ready_models.contains("m2"));
        assert!(fleet.apply_model_gone("p", "m2", 6));
        assert!(!fleet.providers["p"].ready_models.contains("m2"));
        // Delayed ready with older revision cannot resurrect.
        assert!(!fleet.apply_model_ready("p", "m2", 5));
        assert!(!fleet.providers["p"].ready_models.contains("m2"));
    }

    #[test]
    fn data_lane_full_excludes_provider() {
        let mut fleet = FleetState::default();
        let mut p = base("full", "m", 10.0);
        p.data_lane_full = true;
        fleet.upsert(p);
        fleet.upsert(base("ok", "m", 50.0));
        let decision = fleet.admit(&AdmitRequest {
            model: "m".into(),
            attempt: AttemptId::new("a"),
            exclude_providers: HashSet::new(),
            require_tools: false,
            permit_ttl: Duration::from_secs(2),
        });
        match decision {
            AdmissionDecision::Prepare(p) => assert_eq!(p.provider_id, "ok"),
            other => panic!("unexpected {other:?}"),
        }
    }
}
