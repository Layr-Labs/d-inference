//! Money-leg parameter builders (plan §12.5-§12.7, §16).
//!
//! Pure helpers: reservation cost, frozen settlement terms, and the ledger
//! parameter structs with their stable, immutable operation keys
//! (`job:{job}:{leg}` — idempotent per plan §9.3.2). The task executes
//! them through the [`crate::contracts::LedgerFacade`] seam.
//!
//! Rounding: every cost leg uses [`RESERVATION_ROUNDING`] (`CeilV1` — each
//! token-cost product rounds UP to the next micro-USD). Reservations use it
//! so a hold can never under-cover the charge; the same version is frozen
//! into [`FrozenTerms::rounding_version`], so settlement recomputes the
//! charge under the identical rule (plan §12.4).

use darkbloom_core::ids::{AccountId, ApiKeyId, AttemptId, JobId, LeaseId, ModelId, ProviderId};
use darkbloom_core::money::{MicroUsd, Tokens};
use darkbloom_core::request::PreparedFacts;
use darkbloom_core::settlement::{FrozenTerms, Ppm, PricingVersion, RoundingVersion};

use crate::contracts::{PriceCard, ReleaseParams, ReserveParams, ResizeFreezeParams};

use darkbloom_core::ids::{CoordinatorEpoch, SessionEpoch};

/// The one rounding rule this coordinator freezes into terms (plan §12.4).
pub const RESERVATION_ROUNDING: RoundingVersion = RoundingVersion::CeilV1;

/// Fallback payout share used only if the policy carries an out-of-range
/// ppm (config validation rejects those at startup; direct constructions in
/// tests could still exceed one whole).
const FALLBACK_PROVIDER_PAYOUT: Ppm = match Ppm::new(800_000) {
    Some(p) => p,
    None => unreachable!(),
};

/// The provider payout share from policy, validated into [`Ppm`].
pub fn payout_rate(provider_payout_ppm: u32) -> Ppm {
    Ppm::new(provider_payout_ppm).unwrap_or(FALLBACK_PROVIDER_PAYOUT)
}

/// Worst-case pre-flight hold (Go `reservationCost` semantics): estimated
/// prompt cost plus the full requested output bound at the exact per-MTok
/// price card, each leg rounded UP. `None` on arithmetic overflow (treated
/// as reserve failure).
pub fn reservation_cost(
    price: &PriceCard,
    estimated_prompt_tokens: u64,
    requested_max_tokens: u64,
) -> Option<MicroUsd> {
    let prompt = price
        .prompt_micro_per_mtok
        .cost(clamp_tokens(estimated_prompt_tokens), RESERVATION_ROUNDING)?;
    let completion = price
        .completion_micro_per_mtok
        .cost(clamp_tokens(requested_max_tokens), RESERVATION_ROUNDING)?;
    prompt.checked_add(completion)
}

/// Token counts cross the wire as u64 but domain math uses u32 counts;
/// saturate rather than wrap (a >4B-token claim is capped, never trusted).
pub fn clamp_tokens(v: u64) -> Tokens {
    Tokens::new(u32::try_from(v).unwrap_or(u32::MAX))
}

pub struct ReserveInputs<'a> {
    pub job: JobId,
    pub account: AccountId,
    pub api_key: &'a ApiKeyId,
    pub public_model: &'a str,
    pub concrete_model: &'a str,
    pub price: &'a PriceCard,
    pub estimated_prompt_tokens: u64,
    pub requested_max_tokens: u64,
    pub spend_cap: Option<MicroUsd>,
    pub first_content_deadline_ms: i64,
    pub request_deadline_ms: i64,
    pub coordinator_epoch: CoordinatorEpoch,
}

pub fn reserve_params(inputs: &ReserveInputs<'_>) -> Option<ReserveParams> {
    let hold = reservation_cost(
        inputs.price,
        inputs.estimated_prompt_tokens,
        inputs.requested_max_tokens,
    )?;
    Some(ReserveParams {
        operation_key: format!("job:{}:reserve", inputs.job),
        job: inputs.job,
        account: inputs.account,
        api_key: Some(inputs.api_key.clone()),
        public_model: inputs.public_model.to_owned(),
        concrete_model: inputs.concrete_model.to_owned(),
        hold,
        spend_cap: inputs.spend_cap,
        first_content_deadline_ms: inputs.first_content_deadline_ms,
        request_deadline_ms: inputs.request_deadline_ms,
        coordinator_epoch: inputs.coordinator_epoch,
    })
}

pub struct FreezeInputs<'a> {
    pub job: JobId,
    pub attempt: AttemptId,
    pub lease: LeaseId,
    pub provider: ProviderId,
    pub account: AccountId,
    pub api_key: &'a ApiKeyId,
    pub public_model: &'a str,
    pub concrete_model: &'a str,
    pub price: &'a PriceCard,
    pub beneficiary: Option<AccountId>,
    pub catalog_version: u64,
    pub facts: PreparedFacts,
    /// Provider payout share frozen into terms (policy, plan §12.4).
    pub provider_payout_ppm: u32,
    /// Wire-scope fencing identity recorded on the durable attempt row.
    pub session_epoch: SessionEpoch,
    pub dispatch_nonce: [u8; 16],
    pub request_digest: [u8; 32],
    pub coordinator_epoch: CoordinatorEpoch,
}

/// Builds the resize/freeze transaction (plan §12.5): the new hold is the
/// exact prepared billable input plus the funded output bound, and every
/// price/beneficiary term is frozen (plan §12.4). A paid job without a
/// beneficiary cannot reach this point (admission hard gate, plan §11.2);
/// unpaid/self-route jobs fall back to the consumer account with a zero
/// payout economically bounded by the zero charge.
pub fn resize_freeze_params(inputs: &FreezeInputs<'_>) -> Option<ResizeFreezeParams> {
    let billable_input = inputs.facts.billable_input_tokens;
    let max_output = inputs.facts.max_output_tokens;
    let rounding = RESERVATION_ROUNDING;
    let new_hold = inputs
        .price
        .prompt_micro_per_mtok
        .cost(billable_input, rounding)?
        .checked_add(
            inputs
                .price
                .completion_micro_per_mtok
                .cost(max_output, rounding)?,
        )?;
    let frozen = FrozenTerms {
        consumer_account: inputs.account,
        api_key: inputs.api_key.clone(),
        model: ModelId::new(inputs.concrete_model),
        public_model: ModelId::new(inputs.public_model),
        pricing_version: PricingVersion(u32::try_from(inputs.catalog_version).unwrap_or(u32::MAX)),
        rounding_version: rounding,
        billable_input_tokens: billable_input,
        max_output_tokens: max_output,
        input_rate: inputs.price.prompt_micro_per_mtok,
        output_rate: inputs.price.completion_micro_per_mtok,
        provider: inputs.provider,
        provider_beneficiary: inputs.beneficiary.unwrap_or(inputs.account),
        provider_payout_rate: payout_rate(inputs.provider_payout_ppm),
        referral: None,
    };
    Some(ResizeFreezeParams {
        operation_key: format!("job:{}:resize", inputs.job),
        job: inputs.job,
        attempt: inputs.attempt,
        new_hold,
        frozen,
        lease: inputs.lease,
        provider: inputs.provider,
        session_epoch: inputs.session_epoch,
        dispatch_nonce: inputs.dispatch_nonce,
        request_digest: inputs.request_digest,
        coordinator_epoch: inputs.coordinator_epoch,
    })
}

pub fn release_params(
    job: JobId,
    reason: &str,
    coordinator_epoch: CoordinatorEpoch,
) -> ReleaseParams {
    ReleaseParams {
        operation_key: format!("job:{job}:release"),
        job,
        reason: reason.to_owned(),
        coordinator_epoch,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use darkbloom_core::settlement::MicroUsdPerMTokens;

    fn price() -> PriceCard {
        PriceCard {
            prompt_micro_per_mtok: MicroUsdPerMTokens::new(2_000_000).unwrap(),
            completion_micro_per_mtok: MicroUsdPerMTokens::new(5_000_000).unwrap(),
        }
    }

    #[test]
    fn reservation_cost_covers_prompt_and_max_output() {
        let cost = reservation_cost(&price(), 100, 200).unwrap();
        assert_eq!(cost, MicroUsd::new(100 * 2 + 200 * 5));
    }

    #[test]
    fn sub_micro_usd_rates_stay_exact_and_round_up() {
        // 50_000 µUSD/MTok (the Go default input price): 1000 tokens cost
        // exactly 50 µUSD — the per-token card would have inflated this to
        // 1000 µUSD (20x). A single token still rounds UP to 1 µUSD so the
        // hold can never under-cover.
        let card = PriceCard {
            prompt_micro_per_mtok: MicroUsdPerMTokens::new(50_000).unwrap(),
            completion_micro_per_mtok: MicroUsdPerMTokens::ZERO,
        };
        assert_eq!(reservation_cost(&card, 1000, 0).unwrap(), MicroUsd::new(50));
        assert_eq!(reservation_cost(&card, 1, 0).unwrap(), MicroUsd::new(1));
    }

    #[test]
    fn payout_rate_falls_back_on_out_of_range() {
        assert_eq!(payout_rate(750_000).get(), 750_000);
        assert_eq!(payout_rate(2_000_000).get(), 800_000);
    }

    #[test]
    fn freeze_holds_exact_prepared_shape() {
        let inputs = FreezeInputs {
            job: JobId::new(uuid::Uuid::from_u128(1)),
            attempt: AttemptId::new(uuid::Uuid::from_u128(2)),
            lease: LeaseId::new(uuid::Uuid::from_u128(3)),
            provider: ProviderId::new(uuid::Uuid::from_u128(4)),
            account: AccountId::new(uuid::Uuid::from_u128(5)),
            api_key: &ApiKeyId::new("key-1"),
            public_model: "gemma-4",
            concrete_model: "gemma-4-26b-4bit",
            price: &price(),
            beneficiary: Some(AccountId::new(uuid::Uuid::from_u128(6))),
            catalog_version: 7,
            facts: PreparedFacts {
                first_content_eta: darkbloom_core::time::DurationMs::new(100),
                billable_input_tokens: Tokens::new(128),
                max_output_tokens: Tokens::new(64),
            },
            provider_payout_ppm: 800_000,
            session_epoch: SessionEpoch::new(3),
            dispatch_nonce: [7; 16],
            request_digest: [9; 32],
            coordinator_epoch: CoordinatorEpoch::new(9),
        };
        let params = resize_freeze_params(&inputs).unwrap();
        assert_eq!(params.new_hold, MicroUsd::new(128 * 2 + 64 * 5));
        assert_eq!(params.frozen.billable_input_tokens, Tokens::new(128));
        assert_eq!(params.frozen.max_output_tokens, Tokens::new(64));
        assert_eq!(params.frozen.input_rate.get(), 2_000_000);
        assert_eq!(params.frozen.provider_payout_rate.get(), 800_000);
        assert_eq!(params.session_epoch, SessionEpoch::new(3));
        assert_eq!(
            params.operation_key,
            "job:00000000-0000-0000-0000-000000000001:resize"
        );
    }
}
