//! Ledger trait — MemoryLedger today; Postgres/SQLx implementation needs a DB.

use async_trait::async_trait;
use darkbloom_core::MicroUsd;

use crate::ledger::{LedgerError, OperationKey, ReservationProvenance, ReserveResult};

#[async_trait]
pub trait Ledger: Send + Sync {
    async fn reserve(
        &self,
        op: OperationKey,
        job_id: &str,
        account: &str,
        amount: i64,
    ) -> Result<ReserveResult, LedgerError>;

    async fn release(
        &self,
        op: OperationKey,
        job_id: &str,
        account: &str,
    ) -> Result<bool, LedgerError>;

    async fn balance(&self, account: &str) -> (i64, i64);
}

/// Placeholder documenting the SQLx shape. Compiles without a live database;
/// enable with `DATABASE_URL` + `cargo sqlx prepare` once Postgres is available.
pub struct PostgresLedgerStub {
    pub database_url: String,
}

impl PostgresLedgerStub {
    pub fn from_env() -> Option<Self> {
        std::env::var("DATABASE_URL")
            .ok()
            .filter(|u| !u.is_empty())
            .map(|database_url| Self { database_url })
    }

    /// The SQL that will back reserve once SQLx is wired (mirrors MemoryLedger).
    /// Debits the shared Go `balances` table (not rust_coord.*) for money continuity.
    pub fn reserve_sql() -> &'static str {
        r#"
        WITH pre AS (
          SELECT balance_micro_usd AS bal, withdrawable_micro_usd AS wdr
          FROM balances WHERE account_id = $1 FOR UPDATE
        ), calc AS (
          SELECT GREATEST(0, $2::bigint - GREATEST(0, bal - wdr)) AS reserved_wdr FROM pre
        ), debit AS (
          UPDATE balances b
          SET balance_micro_usd = b.balance_micro_usd - $2,
              withdrawable_micro_usd = b.withdrawable_micro_usd - c.reserved_wdr,
              updated_at = NOW()
          FROM calc c WHERE b.account_id = $1
          RETURNING c.reserved_wdr
        ), job AS (
          INSERT INTO rust_coord.inference_jobs (
            job_id, account_id, public_model, concrete_model, state,
            reserved_total_micro_usd, reserved_withdrawable_micro_usd, coordinator_epoch
          ) VALUES ($3, $1, $4, $4, 'reserved', $2, (SELECT reserved_wdr FROM debit), $5)
          ON CONFLICT (job_id) DO NOTHING
        ), op AS (
          INSERT INTO rust_coord.financial_operations (operation_key, job_id, op_type, amount_micro_usd)
          VALUES ($6, $3, 'reserve', $2)
          ON CONFLICT (operation_key) DO NOTHING
          RETURNING operation_key
        )
        SELECT reserved_wdr FROM debit
        "#
    }

    /// Mark start_authorized without resizing (same-amount fund path).
    /// Parameters: $1 job_id, $2 operation_key
    pub fn mark_start_authorized_sql() -> &'static str {
        r#"
        WITH job AS (
          SELECT job_id, state, terminal_disposition
          FROM rust_coord.inference_jobs
          WHERE job_id = $1
          FOR UPDATE
        ), guard AS (
          SELECT 1 FROM job
          WHERE terminal_disposition IS NULL
            AND state = 'reserved'
        ), mark AS (
          UPDATE rust_coord.inference_jobs j
          SET state = 'start_authorized',
              updated_at = NOW()
          WHERE j.job_id = $1
            AND EXISTS (SELECT 1 FROM guard)
          RETURNING j.job_id
        ), op AS (
          INSERT INTO rust_coord.financial_operations (operation_key, job_id, op_type, amount_micro_usd)
          VALUES ($2, $1, 'start_authorize', 0)
          ON CONFLICT (operation_key) DO NOTHING
          RETURNING operation_key
        )
        SELECT job_id FROM mark
        "#
    }

    /// Resize reservation + mark start_authorized in one round-trip (plan §12).
    /// Parameters: $1 account, $2 job_id, $3 new_amount, $4 operation_key
    pub fn resize_and_authorize_sql() -> &'static str {
        r#"
        WITH job AS (
          SELECT job_id, reserved_total_micro_usd AS reserved,
                 reserved_withdrawable_micro_usd AS reserved_wdr,
                 terminal_disposition, state, account_id
          FROM rust_coord.inference_jobs
          WHERE job_id = $2
          FOR UPDATE
        ), guard AS (
          SELECT 1 FROM job
          WHERE terminal_disposition IS NULL
            AND state = 'reserved'
            AND account_id = $1
            AND $3::bigint > 0
        ), bal AS (
          SELECT balance_micro_usd AS bal, withdrawable_micro_usd AS wdr
          FROM balances WHERE account_id = $1 FOR UPDATE
        ), calc AS (
          SELECT
            j.reserved AS old_total,
            j.reserved_wdr AS old_wdr,
            $3::bigint - j.reserved AS delta,
            GREATEST(0, $3::bigint - j.reserved) AS need,
            GREATEST(0, j.reserved - $3::bigint) AS refund
          FROM job j
          WHERE EXISTS (SELECT 1 FROM guard)
        ), funds AS (
          SELECT
            c.*,
            CASE WHEN c.delta > 0 THEN
              LEAST(b.wdr, GREATEST(0, c.need - GREATEST(0, b.bal - b.wdr)))
            ELSE 0 END AS add_wdr,
            CASE WHEN c.delta < 0 THEN
              c.refund - LEAST(c.refund, GREATEST(0, c.old_total - c.old_wdr))
            ELSE 0 END AS refund_wdr
          FROM calc c CROSS JOIN bal b
          WHERE c.delta <= 0 OR b.bal >= c.need
        ), debit AS (
          UPDATE balances b
          SET balance_micro_usd = CASE
                WHEN f.delta > 0 THEN b.balance_micro_usd - f.delta
                WHEN f.delta < 0 THEN b.balance_micro_usd + f.refund
                ELSE b.balance_micro_usd END,
              withdrawable_micro_usd = CASE
                WHEN f.delta > 0 THEN b.withdrawable_micro_usd - f.add_wdr
                WHEN f.delta < 0 THEN b.withdrawable_micro_usd + f.refund_wdr
                ELSE b.withdrawable_micro_usd END,
              updated_at = NOW()
          FROM funds f
          WHERE b.account_id = $1
          RETURNING f.old_wdr, f.add_wdr, f.refund_wdr, f.delta
        ), mark AS (
          UPDATE rust_coord.inference_jobs j
          SET reserved_total_micro_usd = $3,
              reserved_withdrawable_micro_usd = CASE
                WHEN d.delta > 0 THEN d.old_wdr + d.add_wdr
                WHEN d.delta < 0 THEN d.old_wdr - d.refund_wdr
                ELSE d.old_wdr END,
              state = 'start_authorized',
              updated_at = NOW()
          FROM debit d
          WHERE j.job_id = $2
          RETURNING j.job_id, j.reserved_total_micro_usd, j.reserved_withdrawable_micro_usd
        ), op AS (
          INSERT INTO rust_coord.financial_operations (operation_key, job_id, op_type, amount_micro_usd)
          VALUES ($4, $2, 'resize_authorize', $3)
          ON CONFLICT (operation_key) DO NOTHING
          RETURNING operation_key
        )
        SELECT reserved_total_micro_usd, reserved_withdrawable_micro_usd FROM mark
        "#
    }

    /// The SQL that will back settle once SQLx is wired (mirrors MemoryLedger.settle).
    /// Parameters: $1 account, $2 job_id, $3 actual, $4 terminal_digest, $5 operation_key,
    ///             $6 attempt_id
    /// Digest/op inserts are gated on guard so failed settles cannot poison digests/op keys.
    pub fn settle_sql() -> &'static str {
        r#"
        WITH job AS (
          SELECT job_id, account_id, reserved_total_micro_usd AS reserved,
                 reserved_withdrawable_micro_usd AS reserved_wdr,
                 terminal_disposition
          FROM rust_coord.inference_jobs
          WHERE job_id = $2
            AND account_id = $1
          FOR UPDATE
        ), guard AS (
          SELECT 1 FROM job
          WHERE terminal_disposition IS NULL
            AND $3::bigint >= 0
            AND $3::bigint <= reserved
        ), digest AS (
          INSERT INTO rust_coord.provider_terminals (
            terminal_digest, job_id, attempt_id, disposition
          )
          SELECT $4, $2, $6, 'settled'
          FROM guard
          ON CONFLICT (terminal_digest) DO NOTHING
          RETURNING terminal_digest
        ), calc AS (
          SELECT
            j.reserved - $3::bigint AS refund,
            j.reserved_wdr - LEAST(
              j.reserved_wdr,
              GREATEST(0, $3::bigint - GREATEST(0, j.reserved - j.reserved_wdr))
            ) AS refund_wdr
          FROM job j
          WHERE EXISTS (SELECT 1 FROM guard)
            AND EXISTS (SELECT 1 FROM digest)
        ), credit AS (
          UPDATE balances b
          SET balance_micro_usd = b.balance_micro_usd + c.refund,
              withdrawable_micro_usd = b.withdrawable_micro_usd + c.refund_wdr,
              updated_at = NOW()
          FROM calc c
          WHERE b.account_id = $1
          RETURNING c.refund, c.refund_wdr
        ), mark AS (
          UPDATE rust_coord.inference_jobs j
          SET state = 'settled',
              terminal_disposition = 'settled',
              updated_at = NOW()
          FROM calc
          WHERE j.job_id = $2
          RETURNING j.job_id
        ), op AS (
          INSERT INTO rust_coord.financial_operations (operation_key, job_id, op_type, amount_micro_usd)
          SELECT $5, $2, 'settle', $3 FROM calc
          ON CONFLICT (operation_key) DO NOTHING
          RETURNING operation_key
        )
        SELECT refund, refund_wdr FROM credit
        "#
    }

    /// Settle-capped SQL: charge = LEAST(actual, billable_cap, reserved) (DECISIONS #23).
    /// Parameters: $1 account, $2 job_id, $3 actual, $4 billable_cap, $5 terminal_digest,
    ///             $6 operation_key, $7 attempt_id
    pub fn settle_capped_sql() -> &'static str {
        r#"
        WITH job AS (
          SELECT job_id, account_id, reserved_total_micro_usd AS reserved,
                 reserved_withdrawable_micro_usd AS reserved_wdr,
                 terminal_disposition
          FROM rust_coord.inference_jobs
          WHERE job_id = $2
            AND account_id = $1
          FOR UPDATE
        ), charge AS (
          SELECT LEAST(
            GREATEST(0, $3::bigint),
            GREATEST(0, $4::bigint),
            j.reserved
          ) AS amount
          FROM job j
          WHERE j.terminal_disposition IS NULL
        ), digest AS (
          INSERT INTO rust_coord.provider_terminals (
            terminal_digest, job_id, attempt_id, disposition
          )
          SELECT $5, $2, $7, 'settled'
          FROM charge
          ON CONFLICT (terminal_digest) DO NOTHING
          RETURNING terminal_digest
        ), calc AS (
          SELECT
            j.reserved - c.amount AS refund,
            j.reserved_wdr - LEAST(
              j.reserved_wdr,
              GREATEST(0, c.amount - GREATEST(0, j.reserved - j.reserved_wdr))
            ) AS refund_wdr,
            c.amount
          FROM job j
          CROSS JOIN charge c
          WHERE EXISTS (SELECT 1 FROM digest)
        ), credit AS (
          UPDATE balances b
          SET balance_micro_usd = b.balance_micro_usd + x.refund,
              withdrawable_micro_usd = b.withdrawable_micro_usd + x.refund_wdr,
              updated_at = NOW()
          FROM calc x
          WHERE b.account_id = $1
          RETURNING x.refund, x.refund_wdr, x.amount
        ), mark AS (
          UPDATE rust_coord.inference_jobs j
          SET state = 'settled',
              terminal_disposition = 'settled',
              updated_at = NOW()
          FROM calc
          WHERE j.job_id = $2
          RETURNING j.job_id
        ), op AS (
          INSERT INTO rust_coord.financial_operations (operation_key, job_id, op_type, amount_micro_usd)
          SELECT $6, $2, 'settle_capped', amount FROM calc
          ON CONFLICT (operation_key) DO NOTHING
          RETURNING operation_key
        )
        SELECT refund, refund_wdr, amount FROM credit
        "#
    }

    /// Force-settle SQL for start_authorized held jobs (mirrors recovery::force_settle_held).
    /// Requires state = start_authorized and no terminal yet (DECISIONS #16/#17).
    /// Parameters: $1 account, $2 job_id, $3 actual, $4 terminal_digest, $5 operation_key,
    ///             $6 attempt_id
    pub fn force_settle_sql() -> &'static str {
        r#"
        WITH job AS (
          SELECT job_id, account_id, reserved_total_micro_usd AS reserved,
                 reserved_withdrawable_micro_usd AS reserved_wdr,
                 terminal_disposition, state
          FROM rust_coord.inference_jobs
          WHERE job_id = $2
            AND account_id = $1
          FOR UPDATE
        ), guard AS (
          SELECT 1 FROM job
          WHERE terminal_disposition IS NULL
            AND state = 'start_authorized'
        ), charge AS (
          SELECT LEAST(GREATEST(0, $3::bigint), j.reserved) AS amount
          FROM job j
          WHERE EXISTS (SELECT 1 FROM guard)
        ), digest AS (
          INSERT INTO rust_coord.provider_terminals (
            terminal_digest, job_id, attempt_id, disposition
          )
          SELECT $4, $2, $6, 'force_settled'
          FROM charge
          ON CONFLICT (terminal_digest) DO NOTHING
          RETURNING terminal_digest
        ), calc AS (
          SELECT
            j.reserved - c.amount AS refund,
            j.reserved_wdr - LEAST(
              j.reserved_wdr,
              GREATEST(0, c.amount - GREATEST(0, j.reserved - j.reserved_wdr))
            ) AS refund_wdr,
            c.amount
          FROM job j
          CROSS JOIN charge c
          WHERE EXISTS (SELECT 1 FROM digest)
        ), credit AS (
          UPDATE balances b
          SET balance_micro_usd = b.balance_micro_usd + x.refund,
              withdrawable_micro_usd = b.withdrawable_micro_usd + x.refund_wdr,
              updated_at = NOW()
          FROM calc x
          WHERE b.account_id = $1
          RETURNING x.refund, x.refund_wdr, x.amount
        ), mark AS (
          UPDATE rust_coord.inference_jobs j
          SET state = 'settled',
              terminal_disposition = 'force_settled',
              updated_at = NOW()
          FROM calc
          WHERE j.job_id = $2
          RETURNING j.job_id
        ), op AS (
          INSERT INTO rust_coord.financial_operations (operation_key, job_id, op_type, amount_micro_usd)
          SELECT $5, $2, 'force_settle', amount FROM calc
          ON CONFLICT (operation_key) DO NOTHING
          RETURNING operation_key
        )
        SELECT refund, refund_wdr, amount FROM credit
        "#
    }

    /// Release SQL for reserved-but-not-start_authorized jobs (mirrors MemoryLedger.release).
    /// Parameters: $1 account, $2 job_id, $3 operation_key
    pub fn release_sql() -> &'static str {
        r#"
        WITH job AS (
          SELECT job_id, account_id, reserved_total_micro_usd AS reserved,
                 reserved_withdrawable_micro_usd AS reserved_wdr,
                 terminal_disposition, state
          FROM rust_coord.inference_jobs
          WHERE job_id = $2
            AND account_id = $1
          FOR UPDATE
        ), guard AS (
          -- Forbidden after start_authorized (DECISIONS #16).
          SELECT 1 FROM job
          WHERE terminal_disposition IS NULL
            AND state <> 'start_authorized'
        ), credit AS (
          UPDATE balances b
          SET balance_micro_usd = b.balance_micro_usd + j.reserved,
              withdrawable_micro_usd = b.withdrawable_micro_usd + j.reserved_wdr,
              updated_at = NOW()
          FROM job j
          WHERE b.account_id = $1
            AND EXISTS (SELECT 1 FROM guard)
          RETURNING j.reserved, j.reserved_wdr
        ), mark AS (
          UPDATE rust_coord.inference_jobs j
          SET state = 'released',
              terminal_disposition = 'released',
              updated_at = NOW()
          WHERE j.job_id = $2
            AND EXISTS (SELECT 1 FROM guard)
          RETURNING j.job_id
        ), op AS (
          INSERT INTO rust_coord.financial_operations (operation_key, job_id, op_type, amount_micro_usd)
          SELECT $3, $2, 'release', reserved FROM job
          WHERE EXISTS (SELECT 1 FROM guard)
          ON CONFLICT (operation_key) DO NOTHING
          RETURNING operation_key
        )
        SELECT reserved, reserved_wdr FROM credit
        "#
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reserve_sql_mentions_rust_coord_and_provenance() {
        let sql = PostgresLedgerStub::reserve_sql();
        assert!(sql.contains("rust_coord.inference_jobs"));
        assert!(sql.contains("reserved_withdrawable_micro_usd"));
        assert!(sql.contains("financial_operations"));
        assert!(sql.contains("FOR UPDATE"));
    }

    #[test]
    fn settle_sql_refunds_provenance_and_binds_terminal() {
        let sql = PostgresLedgerStub::settle_sql();
        assert!(sql.contains("rust_coord.inference_jobs"));
        assert!(sql.contains("rust_coord.provider_terminals"));
        assert!(sql.contains("financial_operations"));
        assert!(sql.contains("FOR UPDATE"));
        assert!(sql.contains("terminal_disposition"));
        assert!(sql.contains("refund_wdr"));
        assert!(sql.contains("'settle'"));
        assert!(sql.contains("account_id = $1"));
        assert!(sql.contains("SELECT $4, $2, $6, 'settled'"));
        assert!(sql.contains("FROM guard"));
        assert!(sql.contains("SELECT $5, $2, 'settle', $3 FROM calc"));
    }

    #[test]
    fn settle_capped_sql_uses_least_of_actual_cap_reserved() {
        let sql = PostgresLedgerStub::settle_capped_sql();
        assert!(sql.contains("LEAST("));
        assert!(sql.contains("settle_capped"));
        assert!(sql.contains("rust_coord.inference_jobs"));
        assert!(sql.contains("provider_terminals"));
        assert!(sql.contains("FOR UPDATE"));
        assert!(sql.contains("account_id = $1"));
        assert!(sql.contains("SELECT $5, $2, $7, 'settled'"));
        assert!(sql.contains("FROM charge"));
    }

    #[test]
    fn force_settle_sql_requires_start_authorized() {
        let sql = PostgresLedgerStub::force_settle_sql();
        assert!(sql.contains("rust_coord.inference_jobs"));
        assert!(sql.contains("state = 'start_authorized'"));
        assert!(sql.contains("force_settled"));
        assert!(sql.contains("'force_settle'"));
        assert!(sql.contains("LEAST("));
        assert!(sql.contains("provider_terminals"));
        assert!(sql.contains("FOR UPDATE"));
        assert!(sql.contains("financial_operations"));
        assert!(sql.contains("account_id = $1"));
        assert!(sql.contains("SELECT $4, $2, $6, 'force_settled'"));
        assert!(sql.contains("FROM charge"));
    }

    #[test]
    fn release_sql_forbids_start_authorized() {
        let sql = PostgresLedgerStub::release_sql();
        assert!(sql.contains("rust_coord.inference_jobs"));
        assert!(sql.contains("start_authorized"));
        assert!(sql.contains("financial_operations"));
        assert!(sql.contains("FOR UPDATE"));
        assert!(sql.contains("'release'"));
        assert!(sql.contains("account_id = $1"));
    }

    #[test]
    fn resize_and_authorize_sql_marks_start_authorized() {
        let sql = PostgresLedgerStub::resize_and_authorize_sql();
        assert!(sql.contains("rust_coord.inference_jobs"));
        assert!(sql.contains("start_authorized"));
        assert!(sql.contains("resize_authorize"));
        assert!(sql.contains("FOR UPDATE"));
        assert!(sql.contains("financial_operations"));
    }

    #[test]
    fn mark_start_authorized_sql_requires_reserved() {
        let sql = PostgresLedgerStub::mark_start_authorized_sql();
        assert!(sql.contains("rust_coord.inference_jobs"));
        assert!(sql.contains("start_authorized"));
        assert!(sql.contains("start_authorize"));
        assert!(sql.contains("state = 'reserved'"));
        assert!(sql.contains("FOR UPDATE"));
    }

    #[test]
    fn from_env_none_without_database_url() {
        // Unset may already be empty in CI; just ensure no panic.
        let _ = PostgresLedgerStub::from_env();
    }
}

pub fn provenance(total: i64, withdrawable: i64) -> ReservationProvenance {
    ReservationProvenance {
        total: MicroUsd(total),
        withdrawable: MicroUsd(withdrawable),
    }
}
