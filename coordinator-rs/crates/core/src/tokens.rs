//! Validated token, KV-memory, and throughput quantities.

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Failure from exact resource arithmetic.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum ResourceArithmeticError {
    /// Addition or multiplication exceeded the representable range.
    #[error("resource quantity overflow")]
    Overflow,
    /// Subtraction would produce a negative quantity.
    #[error("resource quantity underflow")]
    Underflow,
    /// A rate used as a divisor must be nonzero.
    #[error("resource rate must be greater than zero")]
    ZeroRate,
}

macro_rules! resource_quantity {
    ($(#[$meta:meta])* $name:ident) => {
        $(#[$meta])*
        #[derive(
            Clone,
            Copy,
            Debug,
            Default,
            Eq,
            Hash,
            Ord,
            PartialEq,
            PartialOrd,
            Serialize,
            Deserialize,
        )]
        #[serde(transparent)]
        pub struct $name(u64);

        impl $name {
            /// Zero units.
            pub const ZERO: Self = Self(0);

            /// Creates an exactly represented nonnegative quantity.
            #[must_use]
            pub const fn new(value: u64) -> Self {
                Self(value)
            }

            /// Returns the underlying quantity.
            #[must_use]
            pub const fn get(self) -> u64 {
                self.0
            }

            /// Adds quantities, rejecting overflow.
            pub fn checked_add(self, other: Self) -> Result<Self, ResourceArithmeticError> {
                self.0
                    .checked_add(other.0)
                    .map(Self)
                    .ok_or(ResourceArithmeticError::Overflow)
            }

            /// Subtracts quantities, rejecting underflow.
            pub fn checked_sub(self, other: Self) -> Result<Self, ResourceArithmeticError> {
                self.0
                    .checked_sub(other.0)
                    .map(Self)
                    .ok_or(ResourceArithmeticError::Underflow)
            }
        }
    };
}

resource_quantity!(
    /// A nonnegative number of model tokens.
    TokenCount
);
resource_quantity!(
    /// A nonnegative number of bytes reserved for KV cache.
    KvBytes
);

/// Throughput measured in thousandths of a token per second.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(try_from = "u64", into = "u64")]
pub struct MilliTokensPerSecond(u64);

impl MilliTokensPerSecond {
    /// Creates a nonzero throughput.
    pub const fn new(value: u64) -> Result<Self, ResourceArithmeticError> {
        if value == 0 {
            Err(ResourceArithmeticError::ZeroRate)
        } else {
            Ok(Self(value))
        }
    }

    /// Returns thousandths of a token per second.
    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }
}

impl TryFrom<u64> for MilliTokensPerSecond {
    type Error = ResourceArithmeticError;

    fn try_from(value: u64) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

impl From<MilliTokensPerSecond> for u64 {
    fn from(value: MilliTokensPerSecond) -> Self {
        value.0
    }
}

#[cfg(test)]
mod tests {
    use super::{MilliTokensPerSecond, ResourceArithmeticError, TokenCount};

    #[test]
    fn token_arithmetic_is_exact() {
        assert_eq!(
            TokenCount::new(u64::MAX).checked_add(TokenCount::new(1)),
            Err(ResourceArithmeticError::Overflow)
        );
        assert_eq!(
            TokenCount::ZERO.checked_sub(TokenCount::new(1)),
            Err(ResourceArithmeticError::Underflow)
        );
        assert_eq!(
            MilliTokensPerSecond::new(0),
            Err(ResourceArithmeticError::ZeroRate)
        );
    }
}
