//! Stripe deposit application via ExternalEventInbox + MemoryLedger.
//!
//! Mirrors Go `ApplyStripeDeposit`: event-id idempotency first, then credit.
//! Payload digest binds account/amount/withdrawable (DECISIONS #46).

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

/// Canonical payload digest for a deposit apply (DECISIONS #46).
pub fn deposit_payload_digest(account: &str, total: i64, withdrawable: i64) -> String {
    format!("v1|{account}|{total}|{withdrawable}")
}

/// Apply a Stripe deposit once per `(source, event_id)`.
/// Returns `true` if credit was applied, `false` on identical replay.
/// Returns Conflict when the same event is replayed with different params.
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
    let digest = deposit_payload_digest(account, total, withdrawable);
    if !inbox.observe(source, event_id, &digest)? {
        return Ok(false);
    }
    match ledger.credit_deposit(source, event_id, account, total, withdrawable, &digest) {
        Ok(applied) => Ok(applied),
        Err(err) => {
            // Compensate observe so the event id is not permanently poisoned.
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
/// Outbox insert is gated on credit (DECISIONS #32/#37) so money+side-effect are one txn.
/// Payload digest mismatch aborts before credit (DECISIONS #46).
pub fn deposit_sql() -> &'static str {
    r#"
    WITH params AS (
      SELECT $4::bigint AS total, $5::bigint AS wdr
      WHERE $4::bigint > 0
        AND $5::bigint >= 0
        AND $5::bigint <= $4::bigint
    ), existing AS (
      SELECT payload_digest
      FROM rust_coord.external_events
      WHERE source = $1 AND event_id = $2
      FOR UPDATE
    ), mismatch AS (
      SELECT 1 FROM existing
      WHERE payload_digest IS DISTINCT FROM $6
    ), evt AS (
      INSERT INTO rust_coord.external_events (source, event_id, payload_digest)
      SELECT $1, $2, $6 FROM params
      WHERE NOT EXISTS (SELECT 1 FROM existing)
        AND NOT EXISTS (SELECT 1 FROM mismatch)
      ON CONFLICT (source, event_id) DO NOTHING
      RETURNING source, event_id
    ), credit AS (
      INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd, updated_at)
      SELECT $3, p.total, p.wdr, NOW()
      FROM params p
      WHERE EXISTS (SELECT 1 FROM evt)
        AND NOT EXISTS (SELECT 1 FROM mismatch)
      ON CONFLICT (account_id) DO UPDATE SET
        balance_micro_usd = balances.balance_micro_usd + EXCLUDED.balance_micro_usd,
        withdrawable_micro_usd = balances.withdrawable_micro_usd + EXCLUDED.withdrawable_micro_usd,
        updated_at = NOW()
      RETURNING balance_micro_usd, withdrawable_micro_usd
    ), op AS (
      INSERT INTO rust_coord.financial_operations (
        operation_key, job_id, op_type, amount_micro_usd,
        account_id, terminal_digest, billable_cap_micro_usd
      )
      SELECT 'deposit:' || $1 || ':' || $2, '', 'deposit', $4, $3, $6, $5 FROM credit
      ON CONFLICT (operation_key) DO NOTHING
      RETURNING operation_key
    ), op_row AS (
      SELECT * FROM rust_coord.financial_operations
      WHERE operation_key = 'deposit:' || $1 || ':' || $2
    ), op_ok AS (
      SELECT 1 FROM op_row
      WHERE op_type = 'deposit'
        AND amount_micro_usd = $4
        AND account_id = $3
        AND COALESCE(terminal_digest, '') = COALESCE($6, '')
        AND billable_cap_micro_usd IS NOT DISTINCT FROM $5::bigint
    ), op_conflict AS (
      SELECT 1 FROM op_row WHERE NOT EXISTS (SELECT 1 FROM op_ok)
    ), outbox AS (
      INSERT INTO rust_coord.outbox (kind, payload, attempts)
      SELECT 'billing.deposit_applied',
             jsonb_build_object(
               'source', $1,
               'event_id', $2,
               'account', $3,
               'amount_micro_usd', $4,
               'withdrawable_micro_usd', $5,
               'payload_digest', $6
             ),
             0
      FROM credit
      WHERE EXISTS (SELECT 1 FROM op)
        AND EXISTS (SELECT 1 FROM op_ok)
        AND NOT EXISTS (SELECT 1 FROM op_conflict)
      RETURNING id
    )
    SELECT
      (SELECT balance_micro_usd FROM credit) AS balance_micro_usd,
      (SELECT withdrawable_micro_usd FROM credit) AS withdrawable_micro_usd,
      (SELECT COUNT(*)::int FROM mismatch) AS mismatched,
      EXISTS (SELECT 1 FROM op_conflict) AS param_conflict
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
    fn credit_deposit_op_key_binds_params_without_inbox() {
        // DECISIONS #145: MemoryLedger deposit claim_op mirrors deposit_sql.
        let mut led = MemoryLedger::default();
        let digest = deposit_payload_digest("a", 100_000, 40_000);
        assert!(led
            .credit_deposit("stripe", "evt_bind", "a", 100_000, 40_000, &digest)
            .unwrap());
        assert_eq!(led.balance("a"), (100_000, 40_000));
        // Identical replay is no-op.
        assert!(!led
            .credit_deposit("stripe", "evt_bind", "a", 100_000, 40_000, &digest)
            .unwrap());
        assert_eq!(led.balance("a"), (100_000, 40_000));
        // Mismatched params on same op key → Conflict (no double credit).
        let bad = deposit_payload_digest("a", 100_000, 50_000);
        assert!(matches!(
            led.credit_deposit("stripe", "evt_bind", "a", 100_000, 50_000, &bad),
            Err(LedgerError::Conflict(_))
        ));
        assert_eq!(led.balance("a"), (100_000, 40_000));
    }

    #[test]
    fn mismatched_replay_params_conflict_without_double_credit() {
        let mut inbox = ExternalEventInbox::new();
        let mut led = MemoryLedger::default();
        assert!(apply_stripe_deposit(
            &mut inbox,
            &mut led,
            "stripe",
            "evt_m",
            "a",
            100_000,
            50_000
        )
        .unwrap());
        assert!(matches!(
            apply_stripe_deposit(
                &mut inbox,
                &mut led,
                "stripe",
                "evt_m",
                "a",
                200_000, // different amount
                50_000
            ),
            Err(DepositError::External(ExternalEventError::Conflict(_)))
        ));
        assert!(matches!(
            apply_stripe_deposit(
                &mut inbox,
                &mut led,
                "stripe",
                "evt_m",
                "b", // different account
                100_000,
                50_000
            ),
            Err(DepositError::External(ExternalEventError::Conflict(_)))
        ));
        assert_eq!(led.balance("a"), (100_000, 50_000));
        assert_eq!(led.balance("b").0, 0);
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
        assert!(sql.contains("rust_coord.outbox"));
        assert!(sql.contains("billing.deposit_applied"));
        assert!(sql.contains("WHERE EXISTS (SELECT 1 FROM op)"));
        assert!(sql.contains("op_ok"));
        assert!(sql.contains("param_conflict"));
        assert!(sql.contains("account_id"));
        assert!(sql.contains("mismatch"));
        assert!(sql.contains("IS DISTINCT FROM $6"));
        assert!(sql.contains("NOT EXISTS (SELECT 1 FROM mismatch)"));
    }

    #[test]
    fn deposit_payload_digest_stable() {
        assert_eq!(deposit_payload_digest("a", 100, 50), "v1|a|100|50");
        assert_ne!(
            deposit_payload_digest("a", 100, 50),
            deposit_payload_digest("a", 100, 51)
        );
    }
}
