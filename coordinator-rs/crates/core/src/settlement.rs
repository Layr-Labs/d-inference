//! Pure settlement money math (plan sections 9.3, 12.3, 12.4, 13.6).
//!
//! Invariants enforced here:
//!
//! - Reservation provenance records both the total and the withdrawable
//!   component and releases/refunds both exactly (plan sections 9.3.6, 12.3).
//! - The beneficiary split conserves every micro-USD: provider payout plus
//!   platform fee plus referral reward equals exactly the collected consumer
//!   charge and never exceeds it (plan section 9.3.5).
//! - Usage above frozen funded bounds is capped and flagged for review
//!   (plan section 9.3.8).
//! - Completion usage is capped at the last-accepted-chunk cumulative token
//!   checkpoint: coordinator pipe acceptance, not provider generation, is the
//!   billing boundary (plan sections 10.6, 13.6).
//!
//! Everything is integer micro-USD (`i64`), checked arithmetic only.

use serde::{Deserialize, Serialize};
use thiserror::Error;

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
    fn floor_of(self, amount: MicroUsd) -> MicroUsd {
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

/// How much of a reservation came from total balance and how much of that was
/// withdrawable (plan section 12.3). Release must restore both exactly.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReservationProvenance {
    /// Total balance debited (`H`).
    pub total: MicroUsd,
    /// Withdrawable balance debited (`max(0, H - nonwithdrawable)`).
    pub withdrawable: MicroUsd,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum ProvenanceError {
    #[error("balance, withdrawable, or hold is negative")]
    NegativeInput,
    #[error("withdrawable subset exceeds total balance")]
    WithdrawableExceedsBalance,
    #[error("hold exceeds available balance")]
    InsufficientBalance,
}

/// Reservation provenance from plan section 12.3: nonwithdrawable credit is
/// consumed first, so `reserved_withdrawable = max(0, H - (B - W))`.
pub fn reserve_provenance(
    balance: MicroUsd,
    withdrawable: MicroUsd,
    hold: MicroUsd,
) -> Result<ReservationProvenance, ProvenanceError> {
    if balance.is_negative() || withdrawable.is_negative() || hold.is_negative() {
        return Err(ProvenanceError::NegativeInput);
    }
    if withdrawable > balance {
        return Err(ProvenanceError::WithdrawableExceedsBalance);
    }
    if hold > balance {
        return Err(ProvenanceError::InsufficientBalance);
    }
    // B, W, H are non-negative i64 with W <= B and H <= B: no overflow.
    let nonwithdrawable = balance.saturating_sub_floor_zero(withdrawable);
    let reserved_withdrawable = hold.saturating_sub_floor_zero(nonwithdrawable);
    Ok(ReservationProvenance {
        total: hold,
        withdrawable: reserved_withdrawable,
    })
}

/// Exact amounts a release restores (plan section 12.7): the identity of the
/// stored provenance, expressed as its own type so release paths cannot
/// accidentally restore a recomputed value.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReleaseRestore {
    pub total: MicroUsd,
    pub withdrawable: MicroUsd,
}

/// Full release restores exactly what the reservation removed.
#[must_use]
pub fn release_restore(provenance: ReservationProvenance) -> ReleaseRestore {
    ReleaseRestore {
        total: provenance.total,
        withdrawable: provenance.withdrawable,
    }
}

/// Why settled usage was flagged for operator review.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UsageReviewFlag {
    /// Provider-claimed completion tokens exceeded the coordinator's
    /// last-accepted-chunk checkpoint (plan sections 10.6, 13.6).
    CompletionExceedsAcceptedCheckpoint,
    /// Provider-claimed completion tokens exceeded the frozen funded output
    /// bound — a provider protocol violation (plan section 9.3.8).
    CompletionExceedsFundedBound,
    /// Provider-claimed prompt tokens differ from the frozen billable input
    /// (plan section 12.4 freezes exact billable input).
    PromptDiffersFromFrozenInput,
}

/// Usage the provider claims in its signed terminal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderClaimedUsage {
    pub prompt_tokens: Tokens,
    pub completion_tokens: Tokens,
}

/// Billable completion after applying both caps (accepted checkpoint and
/// funded bound). Pure `min`, with flags for every cap that bit.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BillableCompletion {
    pub tokens: Tokens,
    pub review_flags: Vec<UsageReviewFlag>,
}

/// Cap provider-claimed completion usage at the billing boundary
/// (plan section 13.6) and the frozen funded bound (plan section 9.3.8).
///
/// `accepted_checkpoint` is the cumulative completion-token count of the last
/// chunk successfully enqueued into the consumer-output pipe.
#[must_use]
pub fn billable_completion(
    claimed: Tokens,
    accepted_checkpoint: Tokens,
    funded_bound: Tokens,
) -> BillableCompletion {
    let mut review_flags = Vec::new();
    if claimed > accepted_checkpoint {
        review_flags.push(UsageReviewFlag::CompletionExceedsAcceptedCheckpoint);
    }
    if claimed > funded_bound {
        review_flags.push(UsageReviewFlag::CompletionExceedsFundedBound);
    }
    BillableCompletion {
        tokens: claimed.min(accepted_checkpoint).min(funded_bound),
        review_flags,
    }
}

/// Beneficiary split of one collected consumer charge (plan section 9.3.5).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct SettlementSplit {
    pub consumer_charge: MicroUsd,
    pub provider_payout: MicroUsd,
    pub platform_fee: MicroUsd,
    pub referral_reward: MicroUsd,
}

impl SettlementSplit {
    /// `payout + fee + referral` — always equals `consumer_charge` by
    /// construction; exposed for property tests and reconciliation.
    #[must_use]
    pub fn allocated_total(&self) -> Option<MicroUsd> {
        self.provider_payout
            .checked_add(self.platform_fee)?
            .checked_add(self.referral_reward)
    }
}

/// The complete pure settlement outcome. The ledger service executes this
/// verbatim in one transaction (plan section 12.6); nothing here is advisory.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SettlementOutcome {
    pub split: SettlementSplit,
    /// Unused reservation refunded to the consumer, both provenance
    /// components exact (plan section 12.3).
    pub refund_total: MicroUsd,
    pub refund_withdrawable: MicroUsd,
    /// Withdrawable provenance actually consumed by the charge.
    pub consumed_withdrawable: MicroUsd,
    pub billed_prompt_tokens: Tokens,
    pub billed_completion_tokens: Tokens,
    pub review_flags: Vec<UsageReviewFlag>,
}

impl SettlementOutcome {
    /// Whether the job must land in a reviewed terminal state
    /// (`settled_reviewed`, plan section 12.2).
    #[must_use]
    pub fn needs_review(&self) -> bool {
        !self.review_flags.is_empty()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum SettlementError {
    /// Provenance components are inconsistent (withdrawable > total or
    /// negative), so no arithmetic on them can be trusted.
    #[error("reservation provenance is inconsistent")]
    InconsistentProvenance,
    /// The computed charge exceeds the funded reservation. Charging it would
    /// violate plan section 9.3.5 (credit never exceeds collected funds).
    #[error("computed charge exceeds the funded reservation")]
    ChargeExceedsReservation,
    /// i64 overflow in cost computation.
    #[error("cost arithmetic overflow")]
    Overflow,
}

/// Compute the full settlement for one terminal from frozen terms only.
///
/// - Prompt billing uses the frozen exact billable input (plan section 12.4);
///   a differing provider claim is flagged, never billed.
/// - Completion billing is `min(claimed, accepted checkpoint, funded bound)`
///   (plan sections 13.6, 9.3.8).
/// - The refund restores unused total and unused withdrawable exactly, with
///   nonwithdrawable provenance consumed first (plan section 12.3).
/// - The split conserves the charge exactly (plan section 9.3.5).
pub fn settle(
    terms: &FrozenTerms,
    provenance: ReservationProvenance,
    claimed: ProviderClaimedUsage,
    accepted_checkpoint: Tokens,
) -> Result<SettlementOutcome, SettlementError> {
    if provenance.total.is_negative()
        || provenance.withdrawable.is_negative()
        || provenance.withdrawable > provenance.total
    {
        return Err(SettlementError::InconsistentProvenance);
    }

    let mut completion = billable_completion(
        claimed.completion_tokens,
        accepted_checkpoint,
        terms.max_output_tokens,
    );
    let mut review_flags = core::mem::take(&mut completion.review_flags);
    if claimed.prompt_tokens != terms.billable_input_tokens {
        review_flags.push(UsageReviewFlag::PromptDiffersFromFrozenInput);
    }

    let input_cost = terms
        .input_rate
        .cost(terms.billable_input_tokens, terms.rounding_version)
        .ok_or(SettlementError::Overflow)?;
    let output_cost = terms
        .output_rate
        .cost(completion.tokens, terms.rounding_version)
        .ok_or(SettlementError::Overflow)?;
    let charge = input_cost
        .checked_add(output_cost)
        .ok_or(SettlementError::Overflow)?;
    if charge > provenance.total {
        return Err(SettlementError::ChargeExceedsReservation);
    }

    let split = split_charge(terms, charge);

    // Refund the unused reservation, both provenance components exact.
    // Nonwithdrawable was consumed first at reserve time, so the charge also
    // consumes nonwithdrawable first (plan section 12.3).
    let nonwithdrawable_component = provenance
        .total
        .checked_sub(provenance.withdrawable)
        .ok_or(SettlementError::Overflow)?;
    let consumed_withdrawable = charge
        .saturating_sub_floor_zero(nonwithdrawable_component)
        .min(provenance.withdrawable);
    let refund_total = provenance
        .total
        .checked_sub(charge)
        .ok_or(SettlementError::Overflow)?;
    let refund_withdrawable = provenance
        .withdrawable
        .checked_sub(consumed_withdrawable)
        .ok_or(SettlementError::Overflow)?;

    Ok(SettlementOutcome {
        split,
        refund_total,
        refund_withdrawable,
        consumed_withdrawable,
        billed_prompt_tokens: terms.billable_input_tokens,
        billed_completion_tokens: completion.tokens,
        review_flags,
    })
}

/// Split one collected charge into provider payout, referral reward, and
/// platform fee with exact conservation (plan section 9.3.5).
///
/// Payout floors out of the charge; the referral reward floors out of the
/// gross fee (referrers earn a share of platform fees); the platform fee is
/// the exact remainder, so the three always sum to the charge.
fn split_charge(terms: &FrozenTerms, charge: MicroUsd) -> SettlementSplit {
    let provider_payout = terms.provider_payout_rate.floor_of(charge);
    // charge >= payout because the rate is <= 1 whole and floored.
    let gross_fee = MicroUsd::new(charge.get() - provider_payout.get());
    let referral_reward = match &terms.referral {
        Some(referral) => referral.share.floor_of(gross_fee),
        None => MicroUsd::ZERO,
    };
    let platform_fee = MicroUsd::new(gross_fee.get() - referral_reward.get());
    SettlementSplit {
        consumer_charge: charge,
        provider_payout,
        platform_fee,
        referral_reward,
    }
}
