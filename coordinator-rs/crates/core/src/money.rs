//! Money and token newtypes (plan section 19.3: no floats in money math).
//!
//! `MicroUsd` is signed 64-bit micro-USD. All arithmetic is checked; the only
//! saturating operation is named `saturating_sub_floor_zero` so silent
//! clamping can never masquerade as exact accounting. Splits and provenance
//! math live in [`crate::settlement`] and must conserve every micro-USD
//! (plan sections 9.3.5, 9.3.6, 12.3).

use serde::{Deserialize, Serialize};

/// Signed micro-USD amount. 1_000_000 == $1.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize, Default,
)]
#[serde(transparent)]
pub struct MicroUsd(i64);

impl MicroUsd {
    pub const ZERO: Self = Self(0);

    #[must_use]
    pub const fn new(micro: i64) -> Self {
        Self(micro)
    }

    #[must_use]
    pub const fn get(self) -> i64 {
        self.0
    }

    #[must_use]
    pub const fn is_negative(self) -> bool {
        self.0 < 0
    }

    #[must_use]
    pub const fn is_zero(self) -> bool {
        self.0 == 0
    }

    /// Checked addition; `None` on i64 overflow.
    #[must_use]
    pub fn checked_add(self, other: Self) -> Option<Self> {
        self.0.checked_add(other.0).map(Self)
    }

    /// Checked subtraction; `None` on i64 overflow.
    #[must_use]
    pub fn checked_sub(self, other: Self) -> Option<Self> {
        self.0.checked_sub(other.0).map(Self)
    }

    /// Checked multiplication by a non-negative integer count (token counts).
    #[must_use]
    pub fn checked_mul_count(self, count: u32) -> Option<Self> {
        self.0.checked_mul(i64::from(count)).map(Self)
    }

    /// `max(0, self - other)` — the provenance floor from plan section 12.3
    /// (`reserved_withdrawable = max(0, H - nonwithdrawable)`). Saturation is
    /// explicit in the name: this is the one place money math may clamp.
    #[must_use]
    pub fn saturating_sub_floor_zero(self, other: Self) -> Self {
        Self(self.0.saturating_sub(other.0).max(0))
    }

    /// The smaller of two amounts.
    #[must_use]
    pub fn min(self, other: Self) -> Self {
        Self(self.0.min(other.0))
    }
}

/// Token count (prompt, completion, or reasoning tokens).
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize, Default,
)]
#[serde(transparent)]
pub struct Tokens(u32);

impl Tokens {
    pub const ZERO: Self = Self(0);

    #[must_use]
    pub const fn new(count: u32) -> Self {
        Self(count)
    }

    #[must_use]
    pub const fn get(self) -> u32 {
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

    /// The smaller of two counts. Used at the billing boundary (plan section
    /// 13.6): completion usage is capped at the last accepted checkpoint.
    #[must_use]
    pub fn min(self, other: Self) -> Self {
        Self(self.0.min(other.0))
    }
}
