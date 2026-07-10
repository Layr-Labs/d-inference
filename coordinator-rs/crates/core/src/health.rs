use serde::{Deserialize, Serialize};
use std::time::{Duration, Instant};

/// One provider/model health machine (plan §11.6).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HealthState {
    Healthy,
    Suspect,
    QuarantinedUntil,
    HalfOpen,
}

#[derive(Debug, Clone)]
pub struct HealthMachine {
    pub state: HealthState,
    #[allow(clippy::option_instant)]
    pub quarantine_until: Option<Instant>,
}

impl HealthMachine {
    pub fn healthy() -> Self {
        Self {
            state: HealthState::Healthy,
            quarantine_until: None,
        }
    }

    pub fn on_fault(&mut self, now: Instant, quarantine: Duration) {
        match self.state {
            HealthState::Healthy => self.state = HealthState::Suspect,
            HealthState::Suspect | HealthState::HalfOpen => {
                self.state = HealthState::QuarantinedUntil;
                self.quarantine_until = Some(now + quarantine);
            }
            HealthState::QuarantinedUntil => {}
        }
    }

    pub fn tick(&mut self, now: Instant) {
        if self.state == HealthState::QuarantinedUntil {
            if let Some(until) = self.quarantine_until {
                if now >= until {
                    self.state = HealthState::HalfOpen;
                    self.quarantine_until = None;
                }
            }
        }
    }

    pub fn on_success(&mut self) {
        self.state = HealthState::Healthy;
        self.quarantine_until = None;
    }

    pub fn admits_general_traffic(&self) -> bool {
        matches!(self.state, HealthState::Healthy | HealthState::Suspect)
    }

    /// Half-open allows a single probe admit (plan §11.6). Callers must
    /// treat success via `on_success` and failure via `on_fault`.
    pub fn admits_probe(&self) -> bool {
        matches!(
            self.state,
            HealthState::Healthy | HealthState::Suspect | HealthState::HalfOpen
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quarantine_then_half_open() {
        let mut h = HealthMachine::healthy();
        let t0 = Instant::now();
        h.on_fault(t0, Duration::from_secs(1));
        assert_eq!(h.state, HealthState::Suspect);
        h.on_fault(t0, Duration::from_secs(1));
        assert_eq!(h.state, HealthState::QuarantinedUntil);
        assert!(!h.admits_general_traffic());
        h.tick(t0 + Duration::from_secs(2));
        assert_eq!(h.state, HealthState::HalfOpen);
        assert!(!h.admits_general_traffic());
        assert!(h.admits_probe());
        h.on_success();
        assert_eq!(h.state, HealthState::Healthy);
        assert!(h.admits_general_traffic());
    }

    #[test]
    fn half_open_fault_requarantines() {
        let mut h = HealthMachine::healthy();
        let t0 = Instant::now();
        h.on_fault(t0, Duration::from_millis(1));
        h.on_fault(t0, Duration::from_millis(1));
        h.tick(t0 + Duration::from_secs(1));
        assert_eq!(h.state, HealthState::HalfOpen);
        h.on_fault(t0 + Duration::from_secs(1), Duration::from_secs(60));
        assert_eq!(h.state, HealthState::QuarantinedUntil);
        assert!(!h.admits_probe());
    }
}
