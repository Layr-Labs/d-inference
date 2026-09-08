//! Millisecond time newtypes.
//!
//! The core crate never reads a clock (plan section 19.3: pure domain logic).
//! Callers supply `TimestampMs` explicitly on every reducer call, which makes
//! deadline behavior (plan section 9.2.5: one absolute first-content deadline,
//! never reset) deterministic and property-testable.

use serde::{Deserialize, Serialize};

/// An absolute instant in coordinator time, in milliseconds.
///
/// The origin is caller-defined (wall clock or a test clock); the core crate
/// only ever compares instants and adds durations to them.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize, Default,
)]
#[serde(transparent)]
pub struct TimestampMs(i64);

impl TimestampMs {
    #[must_use]
    pub const fn new(ms: i64) -> Self {
        Self(ms)
    }

    #[must_use]
    pub const fn get(self) -> i64 {
        self.0
    }

    /// Checked addition of a duration; `None` on overflow.
    #[must_use]
    pub fn checked_add(self, d: DurationMs) -> Option<Self> {
        let d = i64::try_from(d.get()).ok()?;
        self.0.checked_add(d).map(Self)
    }

    /// Saturating addition of a duration. Explicitly named per the money/time
    /// arithmetic rule: saturation must be a visible choice at the call site.
    #[must_use]
    pub fn saturating_add(self, d: DurationMs) -> Self {
        let d = i64::try_from(d.get()).unwrap_or(i64::MAX);
        Self(self.0.saturating_add(d))
    }

    /// Milliseconds elapsed since `earlier`, saturating at zero when
    /// `earlier` is in the future.
    #[must_use]
    pub fn saturating_since(self, earlier: TimestampMs) -> DurationMs {
        let delta = self.0.saturating_sub(earlier.0);
        DurationMs::new(u64::try_from(delta).unwrap_or(0))
    }

    /// Milliseconds remaining until `deadline`, saturating at zero once the
    /// deadline has passed.
    #[must_use]
    pub fn saturating_until(self, deadline: TimestampMs) -> DurationMs {
        deadline.saturating_since(self)
    }
}

/// A non-negative span of coordinator time, in milliseconds.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize, Default,
)]
#[serde(transparent)]
pub struct DurationMs(u64);

impl DurationMs {
    pub const ZERO: Self = Self(0);

    #[must_use]
    pub const fn new(ms: u64) -> Self {
        Self(ms)
    }

    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }

    #[must_use]
    pub const fn is_zero(self) -> bool {
        self.0 == 0
    }

    #[must_use]
    pub fn checked_add(self, other: Self) -> Option<Self> {
        self.0.checked_add(other.0).map(Self)
    }

    #[must_use]
    pub fn saturating_sub(self, other: Self) -> Self {
        Self(self.0.saturating_sub(other.0))
    }
}
