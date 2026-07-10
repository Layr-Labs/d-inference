use crate::ids::AttemptId;
use serde::{Deserialize, Serialize};
use std::time::Duration;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DispatchPermit {
    pub attempt: AttemptId,
    pub provider_id: String,
    pub model: String,
    pub expires_after: Duration,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CapacityReason {
    NoWarmProvider,
    FleetSaturated,
    WriterBackpressure,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RejectionReason {
    Untrusted,
    ModelNotReady,
    TraitUnsupported,
    Quarantined,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AdmissionDecision {
    Prepare(DispatchPermit),
    RetryAfter {
        reason: CapacityReason,
        delay: Duration,
    },
    Reject {
        reason: RejectionReason,
    },
}
