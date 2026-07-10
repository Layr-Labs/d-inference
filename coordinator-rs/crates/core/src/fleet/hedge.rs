//! Global prepare-hedge budget (plan section 11.8).
//!
//! Hedges draw from one global bounded budget targeting well under 10% of
//! admissions. The budget is a token bucket that accrues fractionally per
//! admission (not per second — the bound is a fraction of traffic, so it
//! must scale with traffic). An exhausted budget degrades to the
//! sequential-alternate behavior; it never blocks.
//!
//! Pure accounting in milli-tokens; no clock, no floats.

use thiserror::Error;

/// One acquired right to dispatch a prepare hedge. Constructed only by
/// [`HedgeBudget::try_acquire`], so holding one proves the budget allowed it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HedgeToken(());

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum HedgeConfigError {
    /// Plan section 11.8 caps the hedge rate well under 10% of admissions.
    #[error("hedge fraction must be under 100_000 ppm (10%)")]
    FractionTooHigh,
    #[error("burst cap must be at least one hedge")]
    ZeroBurstCap,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HedgeConfig {
    /// Accrual per admission in parts-per-million of one hedge token.
    /// 50_000 ppm = one hedge per 20 admissions (5%).
    fraction_ppm: u32,
    /// Maximum whole hedge tokens the bucket can hold (burst bound).
    burst_cap: u32,
}

impl HedgeConfig {
    /// Validated constructor: the fraction must stay strictly under 10%.
    pub fn new(fraction_ppm: u32, burst_cap: u32) -> Result<Self, HedgeConfigError> {
        if fraction_ppm >= 100_000 {
            return Err(HedgeConfigError::FractionTooHigh);
        }
        if burst_cap == 0 {
            return Err(HedgeConfigError::ZeroBurstCap);
        }
        Ok(Self {
            fraction_ppm,
            burst_cap,
        })
    }

    #[must_use]
    pub const fn fraction_ppm(&self) -> u32 {
        self.fraction_ppm
    }
}

impl Default for HedgeConfig {
    fn default() -> Self {
        Self {
            // 5% of admissions, burst of 4 concurrent hedge rights.
            fraction_ppm: 50_000,
            burst_cap: 4,
        }
    }
}

/// Token bucket in millionths of a hedge token.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HedgeBudget {
    micro_tokens: u64,
    config: HedgeConfig,
}

const MICRO_PER_TOKEN: u64 = 1_000_000;

impl HedgeBudget {
    #[must_use]
    pub fn new(config: HedgeConfig) -> Self {
        Self {
            // Start with one token so early-traffic tails can hedge.
            micro_tokens: MICRO_PER_TOKEN,
            config,
        }
    }

    /// Accrue budget for one admitted request, capped at the burst bound.
    pub fn on_admission(&mut self) {
        let cap = u64::from(self.config.burst_cap) * MICRO_PER_TOKEN;
        self.micro_tokens = self
            .micro_tokens
            .saturating_add(u64::from(self.config.fraction_ppm))
            .min(cap);
    }

    /// Spend one whole token for one hedge. `None` when exhausted — the
    /// caller degrades to sequential-alternate behavior.
    pub fn try_acquire(&mut self) -> Option<HedgeToken> {
        if self.micro_tokens >= MICRO_PER_TOKEN {
            self.micro_tokens -= MICRO_PER_TOKEN;
            Some(HedgeToken(()))
        } else {
            None
        }
    }

    /// Return an unused token (the reducer declined the hedge offer). The
    /// token type guarantees it was really acquired, so refunds cannot mint
    /// budget.
    pub fn refund(&mut self, _token: HedgeToken) {
        let cap = u64::from(self.config.burst_cap) * MICRO_PER_TOKEN;
        self.micro_tokens = self.micro_tokens.saturating_add(MICRO_PER_TOKEN).min(cap);
    }

    /// Whole tokens currently available.
    #[must_use]
    pub fn available(&self) -> u32 {
        u32::try_from(self.micro_tokens / MICRO_PER_TOKEN).unwrap_or(u32::MAX)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_rejects_ten_percent() {
        assert_eq!(
            HedgeConfig::new(100_000, 4),
            Err(HedgeConfigError::FractionTooHigh)
        );
        assert!(HedgeConfig::new(99_999, 4).is_ok());
        assert_eq!(
            HedgeConfig::new(1_000, 0),
            Err(HedgeConfigError::ZeroBurstCap)
        );
    }

    #[test]
    fn accrual_matches_fraction() {
        let config = HedgeConfig::new(50_000, 100).expect("valid");
        let mut budget = HedgeBudget::new(config);
        let initial = budget.available();
        // 20 admissions at 5% accrue exactly one token.
        for _ in 0..20 {
            budget.on_admission();
        }
        assert_eq!(budget.available(), initial + 1);
    }

    #[test]
    fn exhaustion_then_refund() {
        let config = HedgeConfig::new(50_000, 4).expect("valid");
        let mut budget = HedgeBudget::new(config);
        let token = budget.try_acquire().expect("initial token");
        assert!(budget.try_acquire().is_none(), "budget exhausted");
        budget.refund(token);
        assert!(budget.try_acquire().is_some(), "refund restores the token");
    }

    #[test]
    fn burst_cap_bounds_accrual() {
        let config = HedgeConfig::new(99_999, 2).expect("valid");
        let mut budget = HedgeBudget::new(config);
        for _ in 0..1_000 {
            budget.on_admission();
        }
        assert_eq!(budget.available(), 2);
    }
}
