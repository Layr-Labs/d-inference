//! The single-writer fee projection (plan §12.6, §18.1 e).
//!
//! Settlement inserts authoritative `rust_coord.fee_allocations` rows but
//! never touches the materialized platform/referrer balances (that would
//! serialize every settlement on one global account row). This worker folds
//! unprojected rows into the balances and their legacy ledger projections in
//! bounded batches, marking them `projected`.
//!
//! Single-writer discipline: one transaction-scoped advisory lock
//! ([`FEE_PROJECTION_LOCK_KEY`]) makes concurrent projections impossible —
//! a second worker (or a second coordinator during a botched cutover) skips
//! the tick instead of double-crediting. Credit semantics per plan §12.11:
//! platform fees credit total only; referral rewards credit total AND
//! withdrawable. The SQL mirrors the validated projection statement in
//! `fixtures/sql/smoke_money_flow.sql`.

use sqlx::Row;

use crate::ledger::Ledger;

use super::worker::report_depth;
use super::RecoveryConfig;

/// Advisory lock key for the fee projection's single-writer guarantee
/// (`xact`-scoped: released automatically at commit/abort).
pub const FEE_PROJECTION_LOCK_KEY: i64 = 0x6461_726b_6665_6573; // "darkfees"

const PROJECT_SQL: &str = r"
WITH fence AS (
    SELECT 1 FROM rust_coord.coordinator_ownership
    WHERE id = 1 AND fencing_epoch = $1
    FOR SHARE
), claimed AS (
    SELECT f.id, f.job_id, f.beneficiary_account_id, f.kind, f.amount_micro_usd
    FROM rust_coord.fee_allocations f
    WHERE NOT f.projected
      AND EXISTS (SELECT 1 FROM fence)
    ORDER BY f.created_at
    LIMIT $2
    FOR UPDATE SKIP LOCKED
), credited AS (
    INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd)
    SELECT beneficiary_account_id,
           SUM(amount_micro_usd),
           COALESCE(SUM(amount_micro_usd) FILTER (WHERE kind = 'referral'), 0)
    FROM claimed
    GROUP BY beneficiary_account_id
    ON CONFLICT (account_id) DO UPDATE
    SET balance_micro_usd = balances.balance_micro_usd + EXCLUDED.balance_micro_usd,
        withdrawable_micro_usd = balances.withdrawable_micro_usd + EXCLUDED.withdrawable_micro_usd,
        updated_at = NOW()
    RETURNING account_id, balance_micro_usd
), ledger AS (
    INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
    SELECT c.beneficiary_account_id,
           CASE c.kind WHEN 'platform' THEN 'platform_fee' ELSE 'referral_reward' END,
           c.amount_micro_usd,
           cr.balance_micro_usd,
           c.job_id::TEXT
    FROM claimed c
    JOIN credited cr ON cr.account_id = c.beneficiary_account_id
    RETURNING id
), ops AS (
    INSERT INTO rust_coord.financial_operations
        (operation_key, kind, job_id, account_id,
         amount_total_micro_usd, amount_withdrawable_micro_usd, result, coordinator_epoch)
    SELECT 'op.feeproj.' || c.id, 'fee_projection', c.job_id, c.beneficiary_account_id,
           c.amount_micro_usd,
           CASE c.kind WHEN 'referral' THEN c.amount_micro_usd ELSE 0 END,
           '{}'::JSONB, $1
    FROM claimed c
    ON CONFLICT (operation_key) DO NOTHING
    RETURNING operation_key
), marked AS (
    UPDATE rust_coord.fee_allocations f
    SET projected = TRUE, projected_at = NOW()
    FROM claimed
    WHERE f.id = claimed.id
    RETURNING f.id
)
SELECT EXISTS (SELECT 1 FROM fence)          AS fence_ok,
       (SELECT COUNT(*) FROM marked)::BIGINT AS projected
";

/// One projection tick. Returns the number of fee rows folded in.
pub async fn project_fees(ledger: &Ledger, config: &RecoveryConfig) -> anyhow::Result<usize> {
    let (depth, oldest): (i64, Option<f64>) = sqlx::query_as(
        "SELECT COUNT(*), \
                MAX(EXTRACT(EPOCH FROM (NOW() - created_at)))::DOUBLE PRECISION \
         FROM rust_coord.fee_allocations WHERE NOT projected",
    )
    .fetch_one(ledger.pool())
    .await?;
    report_depth("recovery.fee_projection", depth, oldest);
    if depth == 0 {
        return Ok(0);
    }

    let mut tx = ledger.pool().begin().await?;
    let (locked,): (bool,) = sqlx::query_as("SELECT pg_try_advisory_xact_lock($1)")
        .bind(FEE_PROJECTION_LOCK_KEY)
        .fetch_one(&mut *tx)
        .await?;
    if !locked {
        // Another projection writer holds the lock; skip this tick.
        tracing::debug!("fee projection lock busy; skipping tick");
        return Ok(0);
    }

    let epoch = i64::try_from(ledger.coordinator_epoch().get()).unwrap_or(i64::MAX);
    let row = sqlx::query(PROJECT_SQL)
        .bind(epoch)
        .bind(config.batch)
        .fetch_one(&mut *tx)
        .await?;
    let fence_ok: bool = row.try_get("fence_ok")?;
    let projected: i64 = row.try_get("projected")?;
    if !fence_ok {
        tx.rollback().await?;
        anyhow::bail!("fee projection fenced: coordinator epoch is stale (plan §20)");
    }
    tx.commit().await?;
    Ok(usize::try_from(projected).unwrap_or(0))
}
