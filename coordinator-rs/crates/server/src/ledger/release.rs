//! Release and review transitions (plan §12.7, §12.2).
//!
//! `release` is one idempotent statement that restores the EXACT total and
//! withdrawable provenance recorded in the job row (never a recomputed
//! value) and marks the job `released`. Terminals arriving after release are
//! recorded as `late` by the settle path and move no money (plan §12.7).
//!
//! Release is legal from `reserved`/`preparing`/`prepared`/`running` only
//! (plan §12.2). A `start_authorized` job is never auto-released: recovery
//! moves it to `review_pending` instead (plan §18.1) because the provider
//! may hold a funded start.

use serde_json::Value;
use sqlx::Row;

use darkbloom_core::ids::JobId;

use crate::contracts::{LedgerError, ReleaseParams};

use super::error::{map_sqlx, with_retries, TxError};
use super::Ledger;

const RELEASE_SQL: &str = r"
WITH fence AS (
    SELECT fencing_epoch FROM rust_coord.coordinator_ownership
    WHERE id = 1 AND fencing_epoch = $4
    FOR SHARE
), existing AS (
    SELECT result FROM rust_coord.financial_operations WHERE operation_key = $1
), job AS (
    UPDATE rust_coord.inference_jobs j
    SET state = 'released',
        outcome = COALESCE(j.outcome, 'released'),
        error_class = $3,
        version = j.version + 1,
        updated_at = NOW()
    WHERE j.job_id = $2
      AND EXISTS (SELECT 1 FROM fence)
      AND NOT EXISTS (SELECT 1 FROM existing)
      AND j.state IN ('reserved','preparing','prepared','running')
    RETURNING j.account_id,
              j.reserved_total_micro_usd AS total,
              j.reserved_withdrawable_micro_usd AS wd
), op AS (
    INSERT INTO rust_coord.financial_operations
        (operation_key, kind, job_id, account_id,
         amount_total_micro_usd, amount_withdrawable_micro_usd, result, coordinator_epoch)
    SELECT $1, 'release', $2, job.account_id, job.total, job.wd,
           jsonb_build_object('state', 'released', 'reason', $3::TEXT),
           $4
    FROM job
    ON CONFLICT (operation_key) DO NOTHING
    RETURNING operation_key
), refund AS (
    UPDATE balances b
    SET balance_micro_usd = b.balance_micro_usd + job.total,
        withdrawable_micro_usd = b.withdrawable_micro_usd + job.wd,
        updated_at = NOW()
    FROM job, op
    WHERE b.account_id = job.account_id
    RETURNING b.balance_micro_usd
), ledger AS (
    INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
    SELECT job.account_id, 'refund', job.total, refund.balance_micro_usd, $2::TEXT
    FROM job, refund
    WHERE job.total > 0
    RETURNING id
)
SELECT EXISTS (SELECT 1 FROM fence)      AS fence_ok,
       (SELECT e.result FROM existing e) AS existing_result,
       EXISTS (SELECT 1 FROM job)        AS released,
       (SELECT state FROM rust_coord.inference_jobs WHERE job_id = $2) AS state
";

pub(super) async fn release(ledger: &Ledger, p: ReleaseParams) -> Result<(), LedgerError> {
    let epoch = i64::try_from(p.coordinator_epoch.get()).unwrap_or(i64::MAX);
    let row = with_retries(|| {
        let p = p.clone();
        async move {
            sqlx::query(RELEASE_SQL)
                .bind(&p.operation_key)
                .bind(p.job.get())
                .bind(&p.reason)
                .bind(epoch)
                .fetch_one(&ledger.pool)
                .await
                .map_err(TxError::from)
        }
    })
    .await?;

    let fence_ok: bool = row.try_get("fence_ok").map_err(map_sqlx)?;
    let existing: Option<Value> = row.try_get("existing_result").map_err(map_sqlx)?;
    let released: bool = row.try_get("released").map_err(map_sqlx)?;
    let state: Option<String> = row.try_get("state").map_err(map_sqlx)?;

    if !fence_ok {
        return Err(LedgerError::EpochFenced);
    }
    if existing.is_some() || released {
        return Ok(());
    }
    match state.as_deref() {
        // Already released by a different operation key (e.g. a recovery
        // sweeper): the reservation is restored — idempotent success.
        Some("released") | Some("released_reviewed") => Ok(()),
        Some(other) => Err(LedgerError::Conflict(format!(
            "release: job is '{other}', not releasable"
        ))),
        None => Err(LedgerError::Conflict("release: job not found".to_owned())),
    }
}

/// `review_pending` transition (plan §12.2): nonterminal, reservation stays
/// debited, blocks Go rollback until an explicit reviewed disposition.
pub(super) async fn move_to_review(
    ledger: &Ledger,
    job: JobId,
    reason: String,
) -> Result<(), LedgerError> {
    const SQL: &str = r"
WITH fence AS (
    SELECT 1 FROM rust_coord.coordinator_ownership
    WHERE id = 1 AND fencing_epoch = $3
    FOR SHARE
), upd AS (
    UPDATE rust_coord.inference_jobs j
    SET state = 'review_pending', error_class = $2,
        version = j.version + 1, updated_at = NOW()
    WHERE j.job_id = $1
      AND j.state IN ('reserved','preparing','prepared','start_authorized','running')
      AND EXISTS (SELECT 1 FROM fence)
    RETURNING j.job_id
)
SELECT EXISTS (SELECT 1 FROM fence) AS fence_ok,
       EXISTS (SELECT 1 FROM upd)   AS updated,
       (SELECT state FROM rust_coord.inference_jobs WHERE job_id = $1) AS state
";
    let epoch = ledger.current_epoch();
    let row = with_retries(|| {
        let reason = reason.clone();
        async move {
            sqlx::query(SQL)
                .bind(job.get())
                .bind(&reason)
                .bind(epoch)
                .fetch_one(&ledger.pool)
                .await
                .map_err(TxError::from)
        }
    })
    .await?;

    let fence_ok: bool = row.try_get("fence_ok").map_err(map_sqlx)?;
    let updated: bool = row.try_get("updated").map_err(map_sqlx)?;
    let state: Option<String> = row.try_get("state").map_err(map_sqlx)?;

    if !fence_ok {
        return Err(LedgerError::EpochFenced);
    }
    if updated {
        return Ok(());
    }
    match state.as_deref() {
        Some("review_pending") => Ok(()), // idempotent
        Some(other) => Err(LedgerError::Conflict(format!(
            "move_to_review: job is '{other}'"
        ))),
        None => Err(LedgerError::Conflict(
            "move_to_review: job not found".to_owned(),
        )),
    }
}
