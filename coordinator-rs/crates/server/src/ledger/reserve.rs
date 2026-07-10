//! The reserve transaction (plan §12.5): ONE wire round trip.
//!
//! A single statement of data-modifying CTEs, gated on the
//! `financial_operations` operation-key insert exactly like the validated
//! shape in `fixtures/sql/smoke_money_flow.sql`:
//!
//! - `fence`   — epoch compare against `coordinator_ownership` (plan §20),
//!   `FOR SHARE` so a concurrent epoch bump cannot interleave.
//! - `existing`— idempotent replay: a known operation key short-circuits to
//!   the stored result; nothing moves.
//! - `funds`   — locks the balance row and enforces `balance >= hold`
//!   atomically with the debit (no read-then-write gap).
//! - `cap_ok`  — enforces the per-key spend cap against settled spend
//!   (`usage.cost_micro_usd`) plus ACTIVE Rust reservations in the same
//!   statement (plan §12.5).
//! - `op` / `debit` / `job` / `ledger` — operation record, provenance-aware
//!   balance debit (plan §12.3), `rust_coord.inference_jobs` insert, and the
//!   legacy `ledger_entries` projection.

use serde_json::Value;
use sqlx::Row;

use darkbloom_core::money::MicroUsd;
use darkbloom_core::settlement::reserve_provenance;

use crate::contracts::{LedgerError, ReserveOutcome, ReserveParams};

use super::error::{map_sqlx, with_retries, TxError};
use super::Ledger;

const RESERVE_SQL: &str = r"
WITH fence AS (
    SELECT fencing_epoch FROM rust_coord.coordinator_ownership
    WHERE id = 1 AND fencing_epoch = $9
    FOR SHARE
), existing AS (
    SELECT result FROM rust_coord.financial_operations WHERE operation_key = $1
), funds AS (
    SELECT b.account_id,
           GREATEST(0, $4 - (b.balance_micro_usd - b.withdrawable_micro_usd))
               AS reserved_withdrawable
    FROM balances b
    WHERE b.account_id = $2
      AND EXISTS (SELECT 1 FROM fence)
      AND NOT EXISTS (SELECT 1 FROM existing)
      AND b.balance_micro_usd >= $4
    FOR UPDATE OF b
), cap_ok AS (
    SELECT f.account_id, f.reserved_withdrawable
    FROM funds f
    WHERE $5::BIGINT IS NULL
       OR $6 = ''
       OR $5 >= $4
            + COALESCE((SELECT SUM(u.cost_micro_usd) FROM usage u WHERE u.key_id = $6), 0)
            + COALESCE((SELECT SUM(j.reserved_total_micro_usd)
                        FROM rust_coord.inference_jobs j
                        WHERE j.api_key_id = $6
                          AND j.state IN ('reserved','preparing','prepared',
                                          'start_authorized','running','review_pending')), 0)
), op AS (
    INSERT INTO rust_coord.financial_operations
        (operation_key, kind, job_id, account_id,
         amount_total_micro_usd, amount_withdrawable_micro_usd, result, coordinator_epoch)
    SELECT $1, 'reserve', $3, $2,
           -$4, -c.reserved_withdrawable,
           jsonb_build_object('reserved_total', $4::BIGINT,
                              'reserved_withdrawable', c.reserved_withdrawable),
           $9
    FROM cap_ok c
    ON CONFLICT (operation_key) DO NOTHING
    RETURNING operation_key
), debit AS (
    UPDATE balances b
    SET balance_micro_usd = b.balance_micro_usd - $4,
        withdrawable_micro_usd = b.withdrawable_micro_usd - c.reserved_withdrawable,
        updated_at = NOW()
    FROM cap_ok c, op
    WHERE b.account_id = $2
    RETURNING b.balance_micro_usd, c.reserved_withdrawable
), job AS (
    INSERT INTO rust_coord.inference_jobs
        (job_id, account_id, api_key_id, coordinator_epoch, state, version,
         reserve_operation_key, reserved_total_micro_usd, reserved_withdrawable_micro_usd,
         public_model, concrete_model, first_content_deadline, request_deadline)
    SELECT $3, $2, $6, $9, 'reserved', 1,
           $1, $4, d.reserved_withdrawable,
           $7, $8,
           to_timestamp($10::DOUBLE PRECISION / 1000.0),
           to_timestamp($11::DOUBLE PRECISION / 1000.0)
    FROM debit d
    RETURNING job_id
), ledger AS (
    INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
    SELECT $2, 'charge', -$4, d.balance_micro_usd, $3::TEXT
    FROM debit d
    RETURNING id
)
SELECT EXISTS (SELECT 1 FROM fence)                 AS fence_ok,
       (SELECT e.result FROM existing e)            AS existing_result,
       EXISTS (SELECT 1 FROM funds)                 AS funds_ok,
       EXISTS (SELECT 1 FROM cap_ok)                AS cap_passed,
       EXISTS (SELECT 1 FROM op)                    AS inserted,
       (SELECT c.reserved_withdrawable FROM cap_ok c) AS reserved_withdrawable
";

pub(super) async fn reserve(
    ledger: &Ledger,
    p: ReserveParams,
) -> Result<ReserveOutcome, LedgerError> {
    if p.hold.is_negative() {
        return Err(LedgerError::Conflict("negative hold".to_owned()));
    }
    // Validate provenance math is even representable for this hold (checked
    // arithmetic lives in darkbloom_core; the SQL mirrors its formula).
    reserve_provenance(p.hold, MicroUsd::ZERO, p.hold)
        .map_err(|e| LedgerError::Conflict(format!("invalid hold: {e}")))?;

    let account = ledger.accounts.resolve(&ledger.pool, p.account).await?;
    let api_key = p
        .api_key
        .as_ref()
        .map(|k| k.as_str().to_owned())
        .unwrap_or_default();
    let epoch = i64::try_from(p.coordinator_epoch.get()).unwrap_or(i64::MAX);

    let row = with_retries(|| {
        let account = account.clone();
        let api_key = api_key.clone();
        let p = p.clone();
        async move {
            sqlx::query(RESERVE_SQL)
                .bind(&p.operation_key)
                .bind(&account)
                .bind(p.job.get())
                .bind(p.hold.get())
                .bind(p.spend_cap.map(MicroUsd::get))
                .bind(&api_key)
                .bind(&p.public_model)
                .bind(&p.concrete_model)
                .bind(epoch)
                .bind(p.first_content_deadline_ms)
                .bind(p.request_deadline_ms)
                .fetch_one(&ledger.pool)
                .await
                .map_err(TxError::from)
        }
    })
    .await?;

    let fence_ok: bool = row.try_get("fence_ok").map_err(map_sqlx)?;
    let existing: Option<Value> = row.try_get("existing_result").map_err(map_sqlx)?;
    let funds_ok: bool = row.try_get("funds_ok").map_err(map_sqlx)?;
    let cap_passed: bool = row.try_get("cap_passed").map_err(map_sqlx)?;
    let inserted: bool = row.try_get("inserted").map_err(map_sqlx)?;

    if !fence_ok {
        return Err(LedgerError::EpochFenced);
    }
    if let Some(result) = existing {
        return outcome_from_result(&result);
    }
    if !funds_ok {
        return Err(LedgerError::InsufficientFunds);
    }
    if !cap_passed {
        return Err(LedgerError::SpendCapExceeded);
    }
    if inserted {
        let reserved_withdrawable: Option<i64> =
            row.try_get("reserved_withdrawable").map_err(map_sqlx)?;
        return Ok(ReserveOutcome {
            reserved_total: p.hold,
            reserved_withdrawable: MicroUsd::new(reserved_withdrawable.unwrap_or(0)),
        });
    }

    // The op insert conflicted with a commit our snapshot predates (a
    // concurrent identical reserve). Re-read the stored result — never
    // replay the debit on a lost race (plan §12.5).
    let stored: Option<(Value,)> = sqlx::query_as(
        "SELECT result FROM rust_coord.financial_operations WHERE operation_key = $1",
    )
    .bind(&p.operation_key)
    .fetch_optional(&ledger.pool)
    .await
    .map_err(map_sqlx)?;
    match stored {
        Some((result,)) => outcome_from_result(&result),
        None => Err(LedgerError::Unavailable(
            "reserve outcome ambiguous: operation key neither inserted nor found".to_owned(),
        )),
    }
}

/// Decodes the stored operation result written by the first execution
/// (idempotent replay, plan §12.5: query the operation key, never re-debit).
fn outcome_from_result(result: &Value) -> Result<ReserveOutcome, LedgerError> {
    let total = result.get("reserved_total").and_then(Value::as_i64);
    let withdrawable = result.get("reserved_withdrawable").and_then(Value::as_i64);
    match (total, withdrawable) {
        (Some(total), Some(withdrawable)) => Ok(ReserveOutcome {
            reserved_total: MicroUsd::new(total),
            reserved_withdrawable: MicroUsd::new(withdrawable),
        }),
        _ => Err(LedgerError::Conflict(format!(
            "stored reserve result malformed: {result}"
        ))),
    }
}
