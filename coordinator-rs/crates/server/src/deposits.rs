//! Stripe deposit application via ExternalEventInbox + MemoryLedger.
//!
//! Mirrors Go `ApplyStripeDeposit`: event-id idempotency first, then credit.

use crate::external_events::{ExternalEventError, ExternalEventInbox};
use crate::ledger::{LedgerError, MemoryLedger};
use thiserror::Error;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum DepositError {
    #[error(transparent)]
    External(#[from] ExternalEventError),
    #[error(transparent)]
    Ledger(#[from] LedgerError),
}

/// Apply a Stripe deposit once per `(source, event_id)`.
/// Returns `true` if credit was applied, `false` on replay.
pub fn apply_stripe_deposit(
    inbox: &mut ExternalEventInbox,
    ledger: &mut MemoryLedger,
    source: &str,
    event_id: &str,
    account: &str,
    total: i64,
    withdrawable: i64,
) -> Result<bool, DepositError> {
    if !inbox.observe(source, event_id)? {
        return Ok(false);
    }
    ledger.credit(account, total, withdrawable)?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_deposit_credits_replay_is_noop() {
        let mut inbox = ExternalEventInbox::new();
        let mut led = MemoryLedger::default();
        assert!(apply_stripe_deposit(
            &mut inbox,
            &mut led,
            "stripe",
            "evt_1",
            "a",
            1_000_000,
            1_000_000
        )
        .unwrap());
        assert_eq!(led.balance("a"), (1_000_000, 1_000_000));
        assert!(!apply_stripe_deposit(
            &mut inbox,
            &mut led,
            "stripe",
            "evt_1",
            "a",
            1_000_000,
            1_000_000
        )
        .unwrap());
        assert_eq!(led.balance("a"), (1_000_000, 1_000_000));
    }

    #[test]
    fn distinct_events_stack_credits() {
        let mut inbox = ExternalEventInbox::new();
        let mut led = MemoryLedger::default();
        apply_stripe_deposit(&mut inbox, &mut led, "stripe", "e1", "a", 100, 50).unwrap();
        apply_stripe_deposit(&mut inbox, &mut led, "stripe", "e2", "a", 200, 100).unwrap();
        assert_eq!(led.balance("a"), (300, 150));
    }
}
