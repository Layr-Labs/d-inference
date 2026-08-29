//! Money-conservation property tests (plan sections 9.3.5, 9.3.6, 9.3.8,
//! 12.3, 13.6): reserve == charge + refund on both provenance components,
//! splits sum exactly, nothing goes negative, caps flag review.

use darkbloom_core::ids::{AccountId, ApiKeyId, ModelId, ProviderId};
use darkbloom_core::money::{MicroUsd, Tokens};
use darkbloom_core::settlement::{
    billable_completion, release_restore, reserve_provenance, settle, FrozenReferral, FrozenTerms,
    MicroUsdPerMTokens, Ppm, PricingVersion, ProvenanceError, ProviderClaimedUsage,
    RoundingVersion, UsageReviewFlag,
};
use proptest::prelude::*;
use uuid::Uuid;

fn terms_strategy() -> impl Strategy<Value = FrozenTerms> {
    (
        0i64..2_000_000,                        // input rate micro-USD per MTok
        0i64..10_000_000,                       // output rate
        0u32..200_000,                          // billable input tokens
        1u32..32_768,                           // max output tokens
        0u32..=1_000_000,                       // provider payout ppm
        proptest::option::of(0u32..=1_000_000), // referral share ppm
    )
        .prop_map(
            |(input_rate, output_rate, input_toks, max_out, payout_ppm, referral)| FrozenTerms {
                consumer_account: AccountId::new(Uuid::from_u128(1)),
                api_key: ApiKeyId::new("key_test"),
                model: ModelId::new("qwen-test"),
                public_model: ModelId::new("qwen"),
                pricing_version: PricingVersion(1),
                rounding_version: RoundingVersion::CeilV1,
                billable_input_tokens: Tokens::new(input_toks),
                max_output_tokens: Tokens::new(max_out),
                input_rate: MicroUsdPerMTokens::new(input_rate).expect("non-negative"),
                output_rate: MicroUsdPerMTokens::new(output_rate).expect("non-negative"),
                provider: ProviderId::new(Uuid::from_u128(2)),
                provider_beneficiary: AccountId::new(Uuid::from_u128(3)),
                provider_payout_rate: Ppm::new(payout_ppm).expect("<= 1"),
                referral: referral.map(|share| FrozenReferral {
                    beneficiary: AccountId::new(Uuid::from_u128(4)),
                    share: Ppm::new(share).expect("<= 1"),
                }),
            },
        )
}

/// The funded reservation: exactly the maximum possible charge under the
/// frozen terms (input at frozen tokens + output at the funded bound).
fn full_funding(terms: &FrozenTerms) -> MicroUsd {
    let input = terms
        .input_rate
        .cost(terms.billable_input_tokens, terms.rounding_version)
        .expect("bounded inputs cannot overflow");
    let output = terms
        .output_rate
        .cost(terms.max_output_tokens, terms.rounding_version)
        .expect("bounded inputs cannot overflow");
    input.checked_add(output).expect("bounded")
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(2048))]

    /// Plan 12.3: provenance components are consistent and reproduce the
    /// spec formula exactly.
    #[test]
    fn provenance_formula_and_bounds(
        balance in 0i64..1_000_000_000,
        withdrawable_frac in 0u32..=1_000,
        hold_frac in 0u32..=1_000,
    ) {
        let withdrawable = balance / 1_000 * i64::from(withdrawable_frac);
        let hold = balance / 1_000 * i64::from(hold_frac);
        let p = reserve_provenance(
            MicroUsd::new(balance),
            MicroUsd::new(withdrawable),
            MicroUsd::new(hold),
        ).expect("inputs constructed in range");

        prop_assert_eq!(p.total.get(), hold);
        let nonwithdrawable = balance - withdrawable;
        prop_assert_eq!(p.withdrawable.get(), (hold - nonwithdrawable).max(0));
        prop_assert!(p.withdrawable.get() >= 0);
        prop_assert!(p.withdrawable <= p.total);
        prop_assert!(p.withdrawable.get() <= withdrawable);

        // Release restores exactly what was removed.
        let r = release_restore(p);
        prop_assert_eq!(r.total, p.total);
        prop_assert_eq!(r.withdrawable, p.withdrawable);
    }

    #[test]
    fn provenance_rejects_invalid_inputs(balance in 0i64..1_000_000) {
        prop_assert_eq!(
            reserve_provenance(
                MicroUsd::new(balance),
                MicroUsd::new(balance + 1),
                MicroUsd::ZERO,
            ),
            Err(ProvenanceError::WithdrawableExceedsBalance)
        );
        prop_assert_eq!(
            reserve_provenance(
                MicroUsd::new(balance),
                MicroUsd::ZERO,
                MicroUsd::new(balance + 1),
            ),
            Err(ProvenanceError::InsufficientBalance)
        );
        prop_assert_eq!(
            reserve_provenance(MicroUsd::new(-1), MicroUsd::ZERO, MicroUsd::ZERO),
            Err(ProvenanceError::NegativeInput)
        );
    }

    /// The headline conservation property (plan 9.3.5, 9.3.6): the charge
    /// plus refund equals the reservation on both provenance components,
    /// the split sums exactly to the charge, and nothing is negative.
    #[test]
    fn settlement_conserves_every_micro_usd(
        terms in terms_strategy(),
        balance_extra in 0i64..1_000_000_000,
        withdrawable_frac in 0u32..=1_000,
        claimed_completion in 0u32..40_000,
        claimed_prompt in 0u32..250_000,
        checkpoint in 0u32..40_000,
    ) {
        let hold = full_funding(&terms);
        let balance = hold.get() + balance_extra;
        let withdrawable = balance / 1_000 * i64::from(withdrawable_frac);
        let provenance = reserve_provenance(
            MicroUsd::new(balance),
            MicroUsd::new(withdrawable),
            hold,
        ).expect("balance covers hold by construction");

        let outcome = settle(
            &terms,
            provenance,
            ProviderClaimedUsage {
                prompt_tokens: Tokens::new(claimed_prompt),
                completion_tokens: Tokens::new(claimed_completion),
            },
            Tokens::new(checkpoint),
        ).expect("charge is bounded by the funded reservation");

        let split = outcome.split;
        // Split conservation: payout + fee + referral == charge, exactly.
        prop_assert_eq!(
            split.allocated_total().expect("no overflow"),
            split.consumer_charge,
            "beneficiary credit must equal collected funds (9.3.5)"
        );
        prop_assert!(split.provider_payout.get() >= 0);
        prop_assert!(split.platform_fee.get() >= 0);
        prop_assert!(split.referral_reward.get() >= 0);
        prop_assert!(split.consumer_charge.get() >= 0);

        // Total conservation: charge + refund == reservation.
        prop_assert_eq!(
            split.consumer_charge.checked_add(outcome.refund_total).expect("no overflow"),
            provenance.total,
            "reserve == charge + refund (9.3.2/12.3)"
        );
        // Withdrawable conservation: consumed + refunded == reserved.
        prop_assert_eq!(
            outcome.consumed_withdrawable
                .checked_add(outcome.refund_withdrawable)
                .expect("no overflow"),
            provenance.withdrawable,
            "withdrawable provenance must be conserved (9.3.6)"
        );
        prop_assert!(outcome.refund_total.get() >= 0);
        prop_assert!(outcome.refund_withdrawable.get() >= 0);
        prop_assert!(outcome.consumed_withdrawable.get() >= 0);
        prop_assert!(outcome.refund_withdrawable <= outcome.refund_total);

        // Billing boundary (13.6) and funded bound (9.3.8).
        let billed = outcome.billed_completion_tokens;
        prop_assert!(billed <= Tokens::new(claimed_completion));
        prop_assert!(billed <= Tokens::new(checkpoint));
        prop_assert!(billed <= terms.max_output_tokens);
        prop_assert_eq!(outcome.billed_prompt_tokens, terms.billable_input_tokens);

        // Review flags fire exactly when a cap or mismatch applied.
        prop_assert_eq!(
            outcome.review_flags.contains(&UsageReviewFlag::CompletionExceedsAcceptedCheckpoint),
            claimed_completion > checkpoint
        );
        prop_assert_eq!(
            outcome.review_flags.contains(&UsageReviewFlag::CompletionExceedsFundedBound),
            claimed_completion > terms.max_output_tokens.get()
        );
        prop_assert_eq!(
            outcome.review_flags.contains(&UsageReviewFlag::PromptDiffersFromFrozenInput),
            claimed_prompt != terms.billable_input_tokens.get()
        );
    }

    /// The billing boundary is a pure min with flags (plan 13.6).
    #[test]
    fn billable_completion_is_min_of_three(
        claimed in 0u32..100_000,
        checkpoint in 0u32..100_000,
        bound in 0u32..100_000,
    ) {
        let b = billable_completion(
            Tokens::new(claimed),
            Tokens::new(checkpoint),
            Tokens::new(bound),
        );
        prop_assert_eq!(b.tokens.get(), claimed.min(checkpoint).min(bound));
        prop_assert_eq!(
            b.review_flags.contains(&UsageReviewFlag::CompletionExceedsAcceptedCheckpoint),
            claimed > checkpoint
        );
        prop_assert_eq!(
            b.review_flags.contains(&UsageReviewFlag::CompletionExceedsFundedBound),
            claimed > bound
        );
    }

    /// Free settlement (zero rates) refunds everything, on both components.
    #[test]
    fn free_settlement_refunds_everything(
        terms in terms_strategy(),
        balance in 0i64..1_000_000_000,
        withdrawable_frac in 0u32..=1_000,
    ) {
        let mut terms = terms;
        terms.input_rate = MicroUsdPerMTokens::new(0).expect("zero rate");
        terms.output_rate = MicroUsdPerMTokens::new(0).expect("zero rate");
        let withdrawable = balance / 1_000 * i64::from(withdrawable_frac);
        let provenance = reserve_provenance(
            MicroUsd::new(balance),
            MicroUsd::new(withdrawable),
            MicroUsd::ZERO,
        ).expect("zero hold always fits");
        let outcome = settle(
            &terms,
            provenance,
            ProviderClaimedUsage {
                prompt_tokens: terms.billable_input_tokens,
                completion_tokens: Tokens::ZERO,
            },
            Tokens::ZERO,
        ).expect("free settlement");
        prop_assert_eq!(outcome.split.consumer_charge, MicroUsd::ZERO);
        prop_assert_eq!(outcome.refund_total, provenance.total);
        prop_assert_eq!(outcome.refund_withdrawable, provenance.withdrawable);
        prop_assert_eq!(outcome.consumed_withdrawable, MicroUsd::ZERO);
    }
}

#[test]
fn ppm_rejects_over_unity() {
    assert!(Ppm::new(1_000_001).is_none());
    assert!(MicroUsdPerMTokens::new(-1).is_none());
}
