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
///
/// Kill-boundary: amounts are validated **before** observe so a failed credit
/// cannot permanently consume the event id (mirrors one-txn Postgres apply).
pub fn apply_stripe_deposit(
    inbox: &mut ExternalEventInbox,
    ledger: &mut MemoryLedger,
    source: &str,
    event_id: &str,
    account: &str,
    total: i64,
    withdrawable: i64,
) -> Result<bool, DepositError> {
    if total <= 0 || withdrawable < 0 {
        return Err(DepositError::Ledger(LedgerError::InvalidAmount));
    }
    if withdrawable > total {
        return Err(DepositError::Ledger(LedgerError::Conflict(
            "withdrawable exceeds total credit".into(),
        )));
    }
    if !inbox.observe(source, event_id)? {
        return Ok(false);
    }
    match ledger.credit(account, total, withdrawable) {
        Ok(()) => Ok(true),
        Err(err) => {
            // Should be unreachable after pre-validation; compensate observe
            // so the event id is not permanently poisoned.
            let _ = inbox.forget(source, event_id);
            Err(DepositError::Ledger(err))
        }
    }
}

/// Documented SQL for durable Stripe deposit apply (mirrors apply_stripe_deposit).
/// Parameters: $1 source, $2 event_id, $3 account, $4 total, $5 withdrawable, $6 payload_digest
///
/// Kill-boundary (DECISIONS #22): amount guard runs before event insert; credit is an
/// UPSERT so a missing balances row cannot leave a poisoned event id with no credit.
pub fn deposit_sql() -> &'static str {
    r#"
    WITH params AS (
      SELECT $4::bigint AS total, $5::bigint AS wdr
      WHERE $4::bigint > 0
        AND $5::bigint >= 0
        AND $5::bigint <= $4::bigint
    ), evt AS (
      INSERT INTO rust_coord.external_events (source, event_id, payload_digest)
      SELECT $1, $2, $6 FROM params
      ON CONFLICT (source, event_id) DO NOTHING
      RETURNING source, event_id
    ), credit AS (
      INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd, updated_at)
      SELECT $3, p.total, p.wdr, NOW()
      FROM params p
      WHERE EXISTS (SELECT 1 FROM evt)
      ON CONFLICT (account_id) DO UPDATE SET
        balance_micro_usd = balances.balance_micro_usd + EXCLUDED.balance_micro_usd,
        withdrawable_micro_usd = balances.withdrawable_micro_usd + EXCLUDED.withdrawable_micro_usd,
        updated_at = NOW()
      RETURNING balance_micro_usd, withdrawable_micro_usd
    ), op AS (
      INSERT INTO rust_coord.financial_operations (operation_key, job_id, op_type, amount_micro_usd)
      SELECT 'deposit:' || $1 || ':' || $2, '', 'deposit', $4 FROM credit
      ON CONFLICT (operation_key) DO NOTHING
      RETURNING operation_key
    )
    SELECT balance_micro_usd, withdrawable_micro_usd FROM credit
    "#
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

    #[test]
    fn invalid_amount_rejected_before_observe() {
        let mut inbox = ExternalEventInbox::new();
        let mut led = MemoryLedger::default();
        assert!(matches!(
            apply_stripe_deposit(&mut inbox, &mut led, "stripe", "bad", "a", -1, 0),
            Err(DepositError::Ledger(LedgerError::InvalidAmount))
        ));
        assert!(matches!(
            apply_stripe_deposit(&mut inbox, &mut led, "stripe", "bad2", "a", 100, 200),
            Err(DepositError::Ledger(LedgerError::Conflict(_)))
        ));
        assert!(matches!(
            apply_stripe_deposit(&mut inbox, &mut led, "stripe", "bad3", "a", 0, 0),
            Err(DepositError::Ledger(LedgerError::InvalidAmount))
        ));
        // Event ids must not be consumed on validation failure.
        assert!(!inbox.contains("stripe", "bad"));
        assert!(!inbox.contains("stripe", "bad2"));
        assert!(!inbox.contains("stripe", "bad3"));
        // Same ids can still succeed after a valid amount.
        assert!(apply_stripe_deposit(
            &mut inbox,
            &mut led,
            "stripe",
            "bad",
            "a",
            50,
            10
        )
        .unwrap());
        assert_eq!(led.balance("a"), (50, 10));
    }

    #[test]
    fn empty_source_rejected_before_observe() {
        let mut inbox = ExternalEventInbox::new();
        let mut led = MemoryLedger::default();
        assert!(matches!(
            apply_stripe_deposit(&mut inbox, &mut led, "", "evt", "a", 100, 0),
            Err(DepositError::External(ExternalEventError::InvalidKey))
        ));
        assert!(!inbox.contains("", "evt"));
        assert_eq!(led.balance("a").0, 0);
    }

    #[test]
    fn deposit_sql_is_idempotent_external_event() {
        let sql = deposit_sql();
        assert!(sql.contains("rust_coord.external_events"));
        assert!(sql.contains("ON CONFLICT"));
        assert!(sql.contains("balances"));
        assert!(sql.contains("withdrawable_micro_usd"));
        assert!(sql.contains("SELECT $1, $2, $6 FROM params"));
        assert!(sql.contains("INSERT INTO balances"));
        assert!(sql.contains("ON CONFLICT (account_id) DO UPDATE"));
        assert!(sql.contains("WHERE EXISTS (SELECT 1 FROM evt)"));
        assert!(sql.contains("financial_operations"));
        assert!(sql.contains("deposit:"));
    }
}
