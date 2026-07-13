//! Absolute request deadlines and monotonic deadline arithmetic.

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Milliseconds since the Unix epoch.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(transparent)]
pub struct EpochMillis(u64);

impl EpochMillis {
    /// Creates an epoch timestamp.
    #[must_use]
    pub const fn new(value: u64) -> Self {
        Self(value)
    }

    /// Returns milliseconds since the Unix epoch.
    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }

    /// Adds a duration, rejecting timestamp overflow.
    pub fn checked_add(self, duration: DurationMillis) -> Result<Self, DeadlineError> {
        self.0
            .checked_add(duration.get())
            .map(Self)
            .ok_or(DeadlineError::Overflow)
    }
}

/// A nonzero duration in milliseconds.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(try_from = "u64", into = "u64")]
pub struct DurationMillis(u64);

impl DurationMillis {
    /// Creates a nonzero duration.
    pub const fn new(value: u64) -> Result<Self, DeadlineError> {
        if value == 0 {
            Err(DeadlineError::ZeroDuration)
        } else {
            Ok(Self(value))
        }
    }

    /// Returns the duration in milliseconds.
    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }
}

impl TryFrom<u64> for DurationMillis {
    type Error = DeadlineError;

    fn try_from(value: u64) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

impl From<DurationMillis> for u64 {
    fn from(value: DurationMillis) -> Self {
        value.0
    }
}

/// An immutable, nonzero absolute request deadline.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(try_from = "u64", into = "u64")]
pub struct AbsoluteDeadline(u64);

impl AbsoluteDeadline {
    /// Creates an absolute deadline.
    pub const fn new(epoch_millis: u64) -> Result<Self, DeadlineError> {
        if epoch_millis == 0 {
            Err(DeadlineError::ZeroDeadline)
        } else {
            Ok(Self(epoch_millis))
        }
    }

    /// Constructs a deadline by adding a duration to a timestamp.
    pub fn from_start(start: EpochMillis, duration: DurationMillis) -> Result<Self, DeadlineError> {
        Self::new(start.checked_add(duration)?.get())
    }

    /// Returns the deadline as an epoch timestamp.
    #[must_use]
    pub const fn epoch_millis(self) -> EpochMillis {
        EpochMillis(self.0)
    }

    /// Returns true when `now` is at or past the deadline.
    #[must_use]
    pub const fn is_expired_at(self, now: EpochMillis) -> bool {
        now.0 >= self.0
    }

    /// Returns remaining milliseconds, or zero once expired.
    ///
    /// Saturation is intentional here: the semantic remaining duration after
    /// expiration is zero, not a negative duration or an arithmetic error.
    #[must_use]
    pub const fn remaining_at(self, now: EpochMillis) -> u64 {
        self.0.saturating_sub(now.0)
    }
}

impl TryFrom<u64> for AbsoluteDeadline {
    type Error = DeadlineError;

    fn try_from(value: u64) -> Result<Self, Self::Error> {
        Self::new(value)
    }
}

impl From<AbsoluteDeadline> for u64 {
    fn from(value: AbsoluteDeadline) -> Self {
        value.0
    }
}

/// Invalid deadline construction or arithmetic.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum DeadlineError {
    /// An absolute deadline cannot use the sentinel epoch value zero.
    #[error("absolute deadline must be greater than zero")]
    ZeroDeadline,
    /// Durations used to advance time must be nonzero.
    #[error("duration must be greater than zero")]
    ZeroDuration,
    /// Adding a duration exceeded the epoch representation.
    #[error("epoch-millisecond overflow")]
    Overflow,
}

#[cfg(test)]
mod tests {
    use super::{AbsoluteDeadline, DurationMillis, EpochMillis};

    #[test]
    fn remaining_time_stops_at_zero() {
        let deadline = AbsoluteDeadline::new(100).expect("valid deadline");
        assert_eq!(deadline.remaining_at(EpochMillis::new(99)), 1);
        assert_eq!(deadline.remaining_at(EpochMillis::new(100)), 0);
        assert_eq!(deadline.remaining_at(EpochMillis::new(101)), 0);
    }

    #[test]
    fn deadline_addition_rejects_overflow() {
        assert!(
            AbsoluteDeadline::from_start(
                EpochMillis::new(u64::MAX),
                DurationMillis::new(1).expect("nonzero"),
            )
            .is_err()
        );
    }
}
