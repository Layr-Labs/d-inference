//! The composed settlement of one terminal from frozen terms: caps, costs,
//! split, and exact provenance-aware refund (plan sections 12.3, 12.6).

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::money::{MicroUsd, Tokens};
use crate::settlement::billing_boundary::{
    billable_completion, ProviderClaimedUsage, UsageReviewFlag,
};
use crate::settlement::provenance::ReservationProvenance;
use crate::settlement::split::{split_charge, SettlementSplit};
use crate::settlement::terms::FrozenTerms;

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
