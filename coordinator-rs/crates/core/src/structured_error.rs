//! Map structured provider errors to fleet health / trust actions (plan §10.5).

use crate::health::HealthMachine;
use crate::trust::{TrustEpoch, TrustState};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ErrorAction {
    /// Deterministic request error — no health impact, no retry.
    FailRequest,
    /// Capacity — invalidate advisory capacity; one alternate allowed.
    RefreshCapacity,
    /// Model not ready — signal placement; alternate or 429.
    SignalPlacement,
    /// Draining — one alternate.
    Alternate,
    /// Confirmed cancel — release per request state.
    ReleaseCancel,
    /// Fault — record health failure; alternate only if not start_authorized.
    HealthFault,
    /// Security — hard-fence provider.
    HardFence,
}

pub fn action_for_class(class: &str) -> ErrorAction {
    match class {
        "invalid_request" => ErrorAction::FailRequest,
        "capacity" => ErrorAction::RefreshCapacity,
        "model_not_ready" => ErrorAction::SignalPlacement,
        "draining" => ErrorAction::Alternate,
        "cancelled" => ErrorAction::ReleaseCancel,
        "fault" => ErrorAction::HealthFault,
        "security" => ErrorAction::HardFence,
        _ => ErrorAction::HealthFault,
    }
}

pub fn apply_health_action(health: &mut HealthMachine, action: &ErrorAction, now: Instant) {
    match action {
        ErrorAction::HealthFault | ErrorAction::HardFence => {
            health.on_fault(now, Duration::from_secs(60));
        }
        ErrorAction::RefreshCapacity | ErrorAction::SignalPlacement | ErrorAction::Alternate => {}
        ErrorAction::FailRequest | ErrorAction::ReleaseCancel => {}
    }
}

pub fn apply_trust_action(trust: &mut TrustState, action: &ErrorAction) {
    if matches!(action, ErrorAction::HardFence) {
        trust.hard_downgrade(TrustEpoch(trust.trust_epoch.0.max(1)));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::trust::{TrustEvidence, TrustLevel};

    #[test]
    fn security_hard_fences_trust() {
        let mut trust = TrustState::default();
        let _ = trust.apply(TrustEvidence {
            provider_id: "p".into(),
            session_epoch: 1,
            trust_epoch: TrustEpoch(1),
            level: TrustLevel::Hardware,
            challenge_fresh: true,
            runtime_ok: true,
            encrypted_transport: true,
        });
        assert!(trust.publicly_routable());
        apply_trust_action(&mut trust, &ErrorAction::HardFence);
        assert!(!trust.publicly_routable());
    }

    #[test]
    fn capacity_is_not_a_fault() {
        let mut h = HealthMachine::healthy();
        apply_health_action(&mut h, &ErrorAction::RefreshCapacity, Instant::now());
        assert!(h.admits_general_traffic());
    }
}
