//! Mutually exclusive terminal accounting outcomes.

use serde::{Deserialize, Serialize};

use crate::money::MicroUsd;

/// Reason an accounting outcome requires durable manual review.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewReason {
    /// Reported usage conflicts with the authorized reservation.
    UsageMismatch,
    /// A provider outcome is ambiguous after recovery.
    AmbiguousProviderOutcome,
    /// Settlement arithmetic or persistence needs operator intervention.
    AccountingFailure,
}

/// The one terminal accounting disposition for a request.
///
/// Encoding the alternatives as one enum makes settlement, release, and review
/// mutually exclusive by construction.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TerminalDisposition {
    /// Funds were charged for completed, authorized inference.
    Settled {
        /// Exact amount charged.
        charged: MicroUsd,
    },
    /// Reserved funds were released without a charge.
    Released,
    /// Funds remain quarantined pending durable review.
    ReviewPending {
        /// Why automated settlement could not decide safely.
        reason: ReviewReason,
    },
}

impl TerminalDisposition {
    /// Returns true only for a completed settlement.
    #[must_use]
    pub const fn is_settled(self) -> bool {
        matches!(self, Self::Settled { .. })
    }
}
