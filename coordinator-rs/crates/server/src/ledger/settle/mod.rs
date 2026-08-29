//! The settlement transaction (plan §12.6 steps 1–10, §12.8, §10.6).
//!
//! One `READ COMMITTED` transaction:
//!
//! 1.  Epoch fence (`FOR SHARE` on the ownership row, plan §20).
//! 2.  Operation-key replay check (plan §9.3.2).
//! 3.  Insert/validate the signed terminal receipt: the same
//!     `(attempt, digest)` replays the stored disposition; the same attempt
//!     with a DIFFERENT digest marks every receipt of the attempt as a
//!     conflict, moves the job to review, and moves NO money (plan §12.8).
//! 4.  Locks the job and attempt (`SELECT … FOR UPDATE`), then affected
//!     balance rows in deterministic account-id order.
//! 5.  Recomputes the charge with [`darkbloom_core::settlement::settle`]
//!     from the frozen terms stored on the `resize` operation — billable
//!     completion is `min(claimed, accepted checkpoint, funded bound)`.
//! 6.  Any review flag parks the job in `review_pending` WITHOUT moving
//!     money: the reservation stays debited until an explicit reviewed
//!     disposition (plan §12.2 — `review_pending` is nonterminal and
//!     retains its reservation).
//! 7.  Otherwise: consumer refund + provider credit (synchronous row
//!     updates), authoritative `fee_allocations` inserts (projected = FALSE;
//!     the bounded single-writer projection folds them in later, plan
//!     §12.6), legacy usage/earnings/ledger projections, attempt + job
//!     terminal, and an analytics outbox row — all committed together.
//!
//! Module layout: [`transaction`] (fence/replay/state routing flow),
//! [`receipt`] (terminal receipt upsert/dedup/disposition), [`money`]
//! (balance movement, fee rows, legacy projections), [`review`] (parking).

mod money;
mod receipt;
mod review;
mod transaction;

use crate::contracts::{LedgerError, SettleOutcome, SettleParams};

use super::error::with_retries;
use super::Ledger;

/// The public settle entry: the transaction body under bounded
/// serialization retries (plan §12.3).
pub(super) async fn settle(ledger: &Ledger, p: SettleParams) -> Result<SettleOutcome, LedgerError> {
    with_retries(|| {
        let p = p.clone();
        async move { transaction::settle_tx(ledger, &p).await }
    })
    .await
}
