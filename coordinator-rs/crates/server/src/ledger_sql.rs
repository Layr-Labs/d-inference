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
}

pub fn provenance(total: i64, withdrawable: i64) -> ReservationProvenance {
    ReservationProvenance {
        total: MicroUsd(total),
        withdrawable: MicroUsd(withdrawable),
    }
}
