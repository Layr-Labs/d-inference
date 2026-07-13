//! Exact micro-USD monetary arithmetic.

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// A nonnegative monetary amount in millionths of one US dollar.
///
/// Arithmetic never wraps. Callers must handle overflow and underflow
/// explicitly rather than silently changing an accounting outcome.
#[derive(
    Clone, Copy, Debug, Default, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize,
)]
#[serde(transparent)]
pub struct MicroUsd(u64);

impl MicroUsd {
    /// Zero micro-USD.
    pub const ZERO: Self = Self(0);

    /// Creates an amount represented exactly by `value`.
    #[must_use]
    pub const fn new(value: u64) -> Self {
        Self(value)
    }

    /// Returns the underlying number of micro-USD.
    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }

    /// Adds two amounts, rejecting overflow.
    pub fn checked_add(self, other: Self) -> Result<Self, MoneyError> {
        self.0
            .checked_add(other.0)
            .map(Self)
            .ok_or(MoneyError::Overflow)
    }

    /// Subtracts an amount, rejecting underflow.
    pub fn checked_sub(self, other: Self) -> Result<Self, MoneyError> {
        self.0
            .checked_sub(other.0)
            .map(Self)
            .ok_or(MoneyError::Underflow)
    }

    /// Multiplies by a nonnegative integer, rejecting overflow.
    pub fn checked_mul(self, multiplier: u64) -> Result<Self, MoneyError> {
        self.0
            .checked_mul(multiplier)
            .map(Self)
            .ok_or(MoneyError::Overflow)
    }

    /// Converts a wider checked calculation into micro-USD.
    pub fn try_from_u128(value: u128) -> Result<Self, MoneyError> {
        u64::try_from(value)
            .map(Self)
            .map_err(|_| MoneyError::Overflow)
    }
}

/// Exact monetary arithmetic failure.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum MoneyError {
    /// A result exceeded the maximum representable micro-USD.
    #[error("micro-USD overflow")]
    Overflow,
    /// A subtraction would produce a negative monetary amount.
    #[error("micro-USD underflow")]
    Underflow,
}

#[cfg(test)]
mod tests {
    use super::{MicroUsd, MoneyError};

    #[test]
    fn arithmetic_rejects_wraparound() {
        assert_eq!(
            MicroUsd::new(u64::MAX).checked_add(MicroUsd::new(1)),
            Err(MoneyError::Overflow)
        );
        assert_eq!(
            MicroUsd::ZERO.checked_sub(MicroUsd::new(1)),
            Err(MoneyError::Underflow)
        );
    }
}
