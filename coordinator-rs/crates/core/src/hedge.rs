//! Prepare-stage hedge policy (plan §11.8).
//!
//! Starts are never hedged. At most one concurrent prepare hedge before
//! start_authorized, under a global budget.

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

#[derive(Debug, Clone)]
pub struct HedgePolicy {
    /// Fire hedge when primary prepare exceeds this duration.
    pub prepare_latency_trigger: Duration,
    /// Global fraction of requests allowed to hedge (e.g. 0.05 = 5%).
    pub global_budget_fraction: f64,
    pub prepare_ttl: Duration,
}

impl Default for HedgePolicy {
    fn default() -> Self {
        Self {
            prepare_latency_trigger: Duration::from_millis(250),
            global_budget_fraction: 0.05,
            prepare_ttl: Duration::from_secs(15),
        }
    }
}

#[derive(Debug, Default)]
pub struct HedgeBudget {
    total_admits: AtomicU64,
    hedges_fired: AtomicU64,
}

impl HedgeBudget {
    pub fn record_admit(&self) {
        self.total_admits.fetch_add(1, Ordering::Relaxed);
    }

    /// Returns true if a hedge may fire under the global budget.
    pub fn try_consume(&self, policy: &HedgePolicy) -> bool {
        let total = self.total_admits.load(Ordering::Relaxed).max(1) as f64;
        let fired = self.hedges_fired.load(Ordering::Relaxed) as f64;
        if fired / total >= policy.global_budget_fraction {
            return false;
        }
        self.hedges_fired.fetch_add(1, Ordering::Relaxed);
        true
    }

    pub fn should_hedge_on_timer(
        &self,
        policy: &HedgePolicy,
        primary_prepare_elapsed: Duration,
        already_hedged: bool,
        start_authorized: bool,
    ) -> bool {
        if start_authorized || already_hedged {
            return false;
        }
        if primary_prepare_elapsed < policy.prepare_latency_trigger {
            return false;
        }
        self.try_consume(policy)
    }

    pub fn should_hedge_on_eta_miss(
        &self,
        policy: &HedgePolicy,
        prepared_eta: Duration,
        remaining_first_content: Duration,
        already_hedged: bool,
        start_authorized: bool,
    ) -> bool {
        if start_authorized || already_hedged {
            return false;
        }
        if prepared_eta <= remaining_first_content {
            return false;
        }
        self.try_consume(policy)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn budget_caps_hedge_rate() {
        let budget = HedgeBudget::default();
        let policy = HedgePolicy {
            global_budget_fraction: 0.1,
            ..Default::default()
        };
        for _ in 0..100 {
            budget.record_admit();
        }
        let mut fired = 0;
        for _ in 0..100 {
            if budget.should_hedge_on_timer(&policy, Duration::from_secs(1), false, false) {
                fired += 1;
            }
        }
        assert!(fired <= 11, "fired={fired}");
    }

    #[test]
    fn never_hedges_after_start_authorized() {
        let budget = HedgeBudget::default();
        budget.record_admit();
        assert!(!budget.should_hedge_on_timer(
            &HedgePolicy::default(),
            Duration::from_secs(10),
            false,
            true
        ));
    }

    #[test]
    fn five_percent_budget_never_exceeded_under_load() {
        let budget = HedgeBudget::default();
        let policy = HedgePolicy::default(); // 5%
        const N: u64 = 10_000;
        for _ in 0..N {
            budget.record_admit();
        }
        let mut fired = 0u64;
        for _ in 0..N {
            if budget.should_hedge_on_timer(&policy, Duration::from_secs(1), false, false) {
                fired += 1;
            }
        }
        let rate = fired as f64 / N as f64;
        assert!(
            rate <= policy.global_budget_fraction + 0.001,
            "hedge rate {rate} exceeds budget {}",
            policy.global_budget_fraction
        );
    }
}
