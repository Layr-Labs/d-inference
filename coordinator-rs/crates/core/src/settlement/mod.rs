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
//! Everything is integer micro-USD (`i64`), checked arithmetic only. One
//! concern per sibling: [`terms`] (frozen pricing terms), [`provenance`]
//! (reservation provenance math), [`billing_boundary`] (usage caps and
//! review flags), [`split`] (the conserving beneficiary split), and
//! [`settle`] (the composed settlement outcome).

mod billing_boundary;
mod provenance;
mod settle;
mod split;
mod terms;

pub use billing_boundary::{
    billable_completion, BillableCompletion, ProviderClaimedUsage, UsageReviewFlag,
};
pub use provenance::{
    release_restore, reserve_provenance, ProvenanceError, ReleaseRestore, ReservationProvenance,
};
pub use settle::{settle, SettlementError, SettlementOutcome};
pub use split::SettlementSplit;
pub use terms::{
    FrozenReferral, FrozenTerms, MicroUsdPerMTokens, Ppm, PricingVersion, RoundingVersion,
};
