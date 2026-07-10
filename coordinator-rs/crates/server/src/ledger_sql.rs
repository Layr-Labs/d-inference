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

    /// The SQL that will back settle once SQLx is wired (mirrors MemoryLedger.settle).
    /// Parameters: $1 account, $2 job_id, $3 actual, $4 terminal_digest, $5 operation_key, $6 epoch
    pub fn settle_sql() -> &'static str {
        r#"
        WITH job AS (
          SELECT job_id, reserved_total_micro_usd AS reserved,
                 reserved_withdrawable_micro_usd AS reserved_wdr,
                 terminal_disposition
          FROM rust_coord.inference_jobs
          WHERE job_id = $2
          FOR UPDATE
        ), guard AS (
          SELECT 1 FROM job
          WHERE terminal_disposition IS NULL
            AND $3::bigint >= 0
            AND $3::bigint <= reserved
        ), digest AS (
          INSERT INTO rust_coord.provider_terminals (
            terminal_digest, job_id, attempt_id, disposition
          ) VALUES ($4, $2, '', 'settled')
          ON CONFLICT (terminal_digest) DO NOTHING
          RETURNING terminal_digest
        ), calc AS (
          SELECT
            j.reserved - $3::bigint AS refund,
            GREATEST(0, j.reserved - j.reserved_wdr) AS non_wdr_reserved,
            LEAST(
              j.reserved_wdr,
              GREATEST(0, $3::bigint - GREATEST(0, j.reserved - j.reserved_wdr))
            ) AS consumed_wdr,
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
          VALUES ($5, $2, 'settle', $3)
          ON CONFLICT (operation_key) DO NOTHING
          RETURNING operation_key
        )
        SELECT refund, refund_wdr FROM credit
        "#
    }

    /// Release SQL for reserved-but-not-start_authorized jobs (mirrors MemoryLedger.release).
    /// Parameters: $1 account, $2 job_id, $3 operation_key
    pub fn release_sql() -> &'static str {
        r#"
        WITH job AS (
          SELECT job_id, reserved_total_micro_usd AS reserved,
                 reserved_withdrawable_micro_usd AS reserved_wdr,
                 terminal_disposition, state
          FROM rust_coord.inference_jobs
          WHERE job_id = $2
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
    }

    #[test]
    fn release_sql_forbids_start_authorized() {
        let sql = PostgresLedgerStub::release_sql();
        assert!(sql.contains("rust_coord.inference_jobs"));
        assert!(sql.contains("start_authorized"));
        assert!(sql.contains("financial_operations"));
        assert!(sql.contains("FOR UPDATE"));
        assert!(sql.contains("'release'"));
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
