//! Reservation provenance math: what a hold debited and what a release must
//! restore, both components exact (plan sections 9.3.6, 12.3, 12.7).

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::money::MicroUsd;

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
