//! Deterministic, checked inference pricing.

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{
    money::{MicroUsd, MoneyError},
    tokens::TokenCount,
};

const TOKENS_PER_RATE_UNIT: u128 = 1_000_000;

/// Prices expressed in micro-USD per one million tokens.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct PricingSchedule {
    prompt_per_million: MicroUsd,
    completion_per_million: MicroUsd,
    fixed_fee: MicroUsd,
}

impl PricingSchedule {
    /// Creates a pricing schedule.
    #[must_use]
    pub const fn new(
        prompt_per_million: MicroUsd,
        completion_per_million: MicroUsd,
        fixed_fee: MicroUsd,
    ) -> Self {
        Self {
            prompt_per_million,
            completion_per_million,
            fixed_fee,
        }
    }

    /// Computes an exact quote, rounding each nonzero token component up to the
    /// next micro-USD and rejecting any result that does not fit.
    pub fn quote(
        self,
        prompt_tokens: TokenCount,
        completion_tokens: TokenCount,
    ) -> Result<PriceQuote, PricingError> {
        let prompt = component_price(self.prompt_per_million, prompt_tokens)?;
        let completion = component_price(self.completion_per_million, completion_tokens)?;
        let total = self
            .fixed_fee
            .checked_add(prompt)?
            .checked_add(completion)?;
        Ok(PriceQuote {
            prompt,
            completion,
            fixed: self.fixed_fee,
            total,
        })
    }
}

fn component_price(rate: MicroUsd, tokens: TokenCount) -> Result<MicroUsd, PricingError> {
    if rate == MicroUsd::ZERO || tokens == TokenCount::ZERO {
        return Ok(MicroUsd::ZERO);
    }
    let product = u128::from(rate.get())
        .checked_mul(u128::from(tokens.get()))
        .ok_or(PricingError::Overflow)?;
    let rounded = product
        .checked_add(TOKENS_PER_RATE_UNIT - 1)
        .ok_or(PricingError::Overflow)?
        / TOKENS_PER_RATE_UNIT;
    MicroUsd::try_from_u128(rounded).map_err(PricingError::from)
}

/// Checked components of an inference quote.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct PriceQuote {
    /// Prompt-token charge.
    pub prompt: MicroUsd,
    /// Completion-token charge.
    pub completion: MicroUsd,
    /// Fixed request charge.
    pub fixed: MicroUsd,
    /// Sum of all quote components.
    pub total: MicroUsd,
}

/// Pricing or reservation validation failure.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum PricingError {
    /// Checked monetary calculation overflowed.
    #[error("pricing calculation overflow")]
    Overflow,
    /// Exact monetary arithmetic failed.
    #[error(transparent)]
    Money(#[from] MoneyError),
    /// A charge exceeds its authorized reservation.
    #[error("charge of {charged:?} exceeds reservation of {reserved:?}")]
    ReservationExceeded {
        /// Authorized maximum.
        reserved: MicroUsd,
        /// Proposed charge.
        charged: MicroUsd,
    },
}

/// Rejects a charge that exceeds its funding reservation.
pub fn validate_charge(reserved: MicroUsd, charged: MicroUsd) -> Result<(), PricingError> {
    if charged > reserved {
        Err(PricingError::ReservationExceeded { reserved, charged })
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{PricingError, PricingSchedule, validate_charge};
    use crate::{money::MicroUsd, tokens::TokenCount};

    #[test]
    fn rounds_each_nonzero_component_up() {
        let schedule = PricingSchedule::new(MicroUsd::new(1), MicroUsd::new(1), MicroUsd::new(2));
        let quote = schedule
            .quote(TokenCount::new(1), TokenCount::new(1))
            .expect("small quote");
        assert_eq!(quote.prompt, MicroUsd::new(1));
        assert_eq!(quote.completion, MicroUsd::new(1));
        assert_eq!(quote.total, MicroUsd::new(4));
    }

    #[test]
    fn quote_and_reservation_reject_overflow_or_overspend() {
        let schedule =
            PricingSchedule::new(MicroUsd::new(u64::MAX), MicroUsd::ZERO, MicroUsd::ZERO);
        assert_eq!(
            schedule.quote(TokenCount::new(u64::MAX), TokenCount::ZERO),
            Err(PricingError::Money(crate::money::MoneyError::Overflow))
        );
        assert!(matches!(
            validate_charge(MicroUsd::new(4), MicroUsd::new(5)),
            Err(PricingError::ReservationExceeded { .. })
        ));
    }
}
