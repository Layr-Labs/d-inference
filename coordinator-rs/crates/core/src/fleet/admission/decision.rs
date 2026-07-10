//! Admission output types: the described dispatch permit, retry/reject
//! reasons, the typed decision, and the admission configuration.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use super::gates::GateFailure;
use crate::fleet::scoring::ScoringConfig;
use crate::ids::{ModelId, ProviderId};
use crate::time::{DurationMs, TimestampMs};

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
