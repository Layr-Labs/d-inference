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

impl DispatchPermit {
    pub fn is_expired(&self, elapsed: Duration) -> bool {
        elapsed >= self.expires_after
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ids::AttemptId;

    #[test]
    fn permit_expires_after_ttl() {
        let p = DispatchPermit {
            attempt: AttemptId::new("a"),
            provider_id: "p".into(),
            model: "m".into(),
            expires_after: Duration::from_millis(50),
        };
        assert!(!p.is_expired(Duration::from_millis(10)));
        assert!(p.is_expired(Duration::from_millis(50)));
        assert!(p.is_expired(Duration::from_secs(1)));
    }
}
