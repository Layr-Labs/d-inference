//! Frozen pricing terms: every value settlement may consult, fixed before
//! start authorization (plan section 12.4).

use serde::{Deserialize, Serialize};

use crate::ids::{AccountId, ApiKeyId, ModelId, ProviderId};
use crate::money::{MicroUsd, Tokens};

/// Parts-per-million fraction, validated to `0..=1_000_000` at construction so
/// split math can never mint money (plan section 9.3.5).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(try_from = "u32", into = "u32")]
pub struct Ppm(u32);

impl Ppm {
    pub const ZERO: Self = Self(0);
    pub const ONE: Self = Self(1_000_000);

    /// `None` when `v` exceeds one whole (1_000_000 ppm).
    #[must_use]
    pub const fn new(v: u32) -> Option<Self> {
        if v <= 1_000_000 {
            Some(Self(v))
        } else {
            None
        }
    }

    #[must_use]
    pub const fn get(self) -> u32 {
        self.0
    }

    /// `floor(amount * self)` for a non-negative amount. Uses an i128
    /// intermediate, so it cannot overflow; flooring keeps the part strictly
    /// within the whole so remainders stay with the payer side of the split.
    #[must_use]
    pub(super) fn floor_of(self, amount: MicroUsd) -> MicroUsd {
        debug_assert!(!amount.is_negative());
        let product = i128::from(amount.get()) * i128::from(self.0) / 1_000_000i128;
        // product <= amount <= i64::MAX, so the conversion is lossless.
        MicroUsd::new(product as i64)
    }
}

impl TryFrom<u32> for Ppm {
    type Error = String;

    fn try_from(v: u32) -> Result<Self, Self::Error> {
        Self::new(v).ok_or_else(|| format!("ppm {v} exceeds 1_000_000"))
    }
}

impl From<Ppm> for u32 {
    fn from(p: Ppm) -> u32 {
        p.0
    }
}

/// Frozen rounding rule version (plan section 12.4). Settlement must never
/// re-read a mutable rounding rule; the version is frozen before start.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RoundingVersion {
    /// Per-cost ceiling: each token-cost product rounds up to the next
    /// micro-USD, so fractional micro-USD never bill as zero.
    CeilV1,
}

/// Pricing schedule version identifier frozen into the job (plan section 12.4).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(transparent)]
pub struct PricingVersion(pub u32);

/// Token price in micro-USD per one million tokens. Integer-exact: cost
/// computation uses an i128 intermediate and the frozen rounding version.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct MicroUsdPerMTokens(i64);

impl MicroUsdPerMTokens {
    pub const ZERO: Self = Self(0);

    /// `None` for negative rates: a negative price would let usage mint money.
    #[must_use]
    pub const fn new(rate: i64) -> Option<Self> {
        if rate >= 0 {
            Some(Self(rate))
        } else {
            None
        }
    }

    #[must_use]
    pub const fn get(self) -> i64 {
        self.0
    }

    /// Cost of `tokens` at this rate under `rounding`; `None` on i64 overflow.
    #[must_use]
    pub fn cost(self, tokens: Tokens, rounding: RoundingVersion) -> Option<MicroUsd> {
        let product = i128::from(self.0) * i128::from(tokens.get());
        let cost = match rounding {
            RoundingVersion::CeilV1 => (product + 999_999) / 1_000_000,
        };
        i64::try_from(cost).ok().map(MicroUsd::new)
    }
}

/// Referral beneficiary and share, frozen before start (plan section 12.4).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FrozenReferral {
    pub beneficiary: AccountId,
    /// Referrer share of the gross platform fee.
    pub share: Ppm,
}

/// Every term settlement may consult, frozen before `start_authorized`
/// (plan section 12.4). No settlement path re-reads mutable pricing, user
/// role, provider ownership, or referral rules.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FrozenTerms {
    pub consumer_account: AccountId,
    pub api_key: ApiKeyId,
    /// Concrete model as routed.
    pub model: ModelId,
    /// Public model name the consumer requested (may alias `model`).
    pub public_model: ModelId,
    pub pricing_version: PricingVersion,
    pub rounding_version: RoundingVersion,
    /// Exact billable input from the provider's prepared facts, bounded by
    /// the coordinator's request-shape upper bound (plan section 12.5).
    pub billable_input_tokens: Tokens,
    /// Funded output bound. Output beyond this is capped and reviewed
    /// (plan section 9.3.8).
    pub max_output_tokens: Tokens,
    pub input_rate: MicroUsdPerMTokens,
    pub output_rate: MicroUsdPerMTokens,
    pub provider: ProviderId,
    /// Provider beneficiary account (plan section 11.2: required for paid
    /// public routing).
    pub provider_beneficiary: AccountId,
    /// Provider payout share of the consumer charge.
    pub provider_payout_rate: Ppm,
    /// Referral carve-out of the gross platform fee, when present.
    pub referral: Option<FrozenReferral>,
}
