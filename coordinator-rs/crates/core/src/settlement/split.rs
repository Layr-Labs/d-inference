//! The conserving beneficiary split of one collected consumer charge
//! (plan section 9.3.5).
//!
//! Invariant: provider payout + platform fee + referral reward equals the
//! consumer charge exactly — the split can never mint or leak a micro-USD.

use serde::{Deserialize, Serialize};

use crate::money::MicroUsd;
use crate::settlement::terms::FrozenTerms;

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

/// Split one collected charge into provider payout, referral reward, and
/// platform fee with exact conservation (plan section 9.3.5).
///
/// Payout floors out of the charge; the referral reward floors out of the
/// gross fee (referrers earn a share of platform fees); the platform fee is
/// the exact remainder, so the three always sum to the charge.
pub(super) fn split_charge(terms: &FrozenTerms, charge: MicroUsd) -> SettlementSplit {
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
