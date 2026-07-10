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
    /// Op claim gates job insert + debit (DECISIONS #15/#33): reused op keys cannot
    /// debit a second job. Job insert is gated first among money CTEs; debit only
    /// runs when the job row is newly created. Orphaned op claims (job conflict)
    /// are cleaned up in-statement.
    /// Parameters: $1 account, $2 amount, $3 job_id, $4 model, $5 epoch, $6 operation_key
    /// Op params bind account+amount+job (DECISIONS #34/#138): mismatched reuse
    /// sets param_conflict=true so the caller must refuse (not treat as replay).
    pub fn reserve_sql() -> &'static str {
        r#"
        WITH bal AS (
          SELECT balance_micro_usd AS bal, withdrawable_micro_usd AS wdr
          FROM balances WHERE account_id = $1 FOR UPDATE
        ), existing AS (
          SELECT 1 FROM rust_coord.inference_jobs WHERE job_id = $3 FOR UPDATE
        ), eligible AS (
          SELECT
            GREATEST(0, $2::bigint - GREATEST(0, bal - wdr)) AS reserved_wdr
          FROM bal
          WHERE NOT EXISTS (SELECT 1 FROM existing)
            AND $2::bigint > 0
            AND bal >= $2::bigint
        ), op AS (
          INSERT INTO rust_coord.financial_operations (
            operation_key, job_id, op_type, amount_micro_usd,
            account_id, terminal_digest, billable_cap_micro_usd
          )
          SELECT $6, $3, 'reserve', $2, $1, '', NULL FROM eligible
          ON CONFLICT (operation_key) DO NOTHING
          RETURNING operation_key
        ), op_row AS (
          SELECT * FROM rust_coord.financial_operations WHERE operation_key = $6
        ), op_ok AS (
          SELECT 1 FROM op_row
          WHERE job_id = $3
            AND op_type = 'reserve'
            AND amount_micro_usd = $2
            AND account_id = $1
            AND COALESCE(terminal_digest, '') = ''
            AND billable_cap_micro_usd IS NULL
        ), op_conflict AS (
          SELECT 1 FROM op_row WHERE NOT EXISTS (SELECT 1 FROM op_ok)
        ), job AS (
          INSERT INTO rust_coord.inference_jobs (
            job_id, account_id, public_model, concrete_model, state,
            reserved_total_micro_usd, reserved_withdrawable_micro_usd, coordinator_epoch
          )
          SELECT $3, $1, $4, $4, 'reserved', $2, e.reserved_wdr, $5
          FROM eligible e
          WHERE EXISTS (SELECT 1 FROM op)
            AND EXISTS (SELECT 1 FROM op_ok)
            AND NOT EXISTS (SELECT 1 FROM op_conflict)
          ON CONFLICT (job_id) DO NOTHING
          RETURNING job_id, reserved_withdrawable_micro_usd AS reserved_wdr
        ), debit AS (
          UPDATE balances b
          SET balance_micro_usd = b.balance_micro_usd - $2,
              withdrawable_micro_usd = b.withdrawable_micro_usd - j.reserved_wdr,
              updated_at = NOW()
          FROM job j
          WHERE b.account_id = $1
          RETURNING j.reserved_wdr
        ), cleanup_op AS (
          DELETE FROM rust_coord.financial_operations fo
          WHERE fo.operation_key = $6
            AND EXISTS (SELECT 1 FROM op)
            AND NOT EXISTS (SELECT 1 FROM job)
          RETURNING fo.operation_key
        )
        SELECT
          (SELECT reserved_wdr FROM debit) AS reserved_wdr,
          EXISTS (SELECT 1 FROM op_conflict) AS param_conflict
        "#
    }

    /// Mark start_authorized without resizing (same-amount fund path).
    /// Parameters: $1 job_id, $2 account_id, $3 operation_key, $4 fencing_epoch
    /// Account bind: job row must match caller account (DECISIONS #24/#31).
    /// Op claim gates the state transition (DECISIONS #33).
    /// Fencing epoch must match (or job unbound=0) — DECISIONS #52.
    pub fn mark_start_authorized_sql() -> &'static str {
        r#"
        WITH job AS (
          SELECT job_id, state, terminal_disposition, account_id, coordinator_epoch
          FROM rust_coord.inference_jobs
          WHERE job_id = $1
            AND account_id = $2
          FOR UPDATE
        ), guard AS (
          SELECT 1 FROM job
          WHERE terminal_disposition IS NULL
            AND state = 'reserved'
            AND (coordinator_epoch = 0 OR coordinator_epoch = $4::bigint)
        ), op AS (
          INSERT INTO rust_coord.financial_operations (
            operation_key, job_id, op_type, amount_micro_usd,
            account_id, terminal_digest, billable_cap_micro_usd
          )
          SELECT $3, $1, 'start_authorize', 0, $2, '', NULL FROM guard
          ON CONFLICT (operation_key) DO NOTHING
          RETURNING operation_key
        ), op_row AS (
          SELECT * FROM rust_coord.financial_operations WHERE operation_key = $3
        ), op_ok AS (
          SELECT 1 FROM op_row
          WHERE job_id = $1
            AND op_type = 'start_authorize'
            AND amount_micro_usd = 0
            AND account_id = $2
            AND COALESCE(terminal_digest, '') = ''
            AND billable_cap_micro_usd IS NULL
        ), op_conflict AS (
          SELECT 1 FROM op_row WHERE NOT EXISTS (SELECT 1 FROM op_ok)
        ), mark AS (
          UPDATE rust_coord.inference_jobs j
          SET state = 'start_authorized',
              updated_at = NOW()
          WHERE j.job_id = $1
            AND j.account_id = $2
            AND EXISTS (SELECT 1 FROM guard)
            AND EXISTS (SELECT 1 FROM op)
            AND EXISTS (SELECT 1 FROM op_ok)
            AND NOT EXISTS (SELECT 1 FROM op_conflict)
          RETURNING j.job_id
        ), cleanup_op AS (
          DELETE FROM rust_coord.financial_operations fo
          WHERE fo.operation_key = $3
            AND EXISTS (SELECT 1 FROM op)
            AND NOT EXISTS (SELECT 1 FROM mark)
          RETURNING fo.operation_key
        )
        SELECT
          (SELECT job_id FROM mark) AS job_id,
          EXISTS (SELECT 1 FROM op_conflict) AS param_conflict
        "#
    }

    /// Resize reservation + mark start_authorized in one round-trip (plan §12).
    /// Parameters: $1 account, $2 job_id, $3 new_amount, $4 operation_key, $5 fencing_epoch
    /// Op claim gates debit/mark so reused op keys cannot move funds (DECISIONS #33).
    /// Fencing epoch must match (or job unbound=0) — DECISIONS #52.
    pub fn resize_and_authorize_sql() -> &'static str {
        r#"
        WITH job AS (
          SELECT job_id, reserved_total_micro_usd AS reserved,
                 reserved_withdrawable_micro_usd AS reserved_wdr,
                 terminal_disposition, state, account_id, coordinator_epoch
          FROM rust_coord.inference_jobs
          WHERE job_id = $2
            AND account_id = $1
          FOR UPDATE
        ), guard AS (
          SELECT 1 FROM job
          WHERE terminal_disposition IS NULL
            AND state = 'reserved'
            AND $3::bigint > 0
            AND (coordinator_epoch = 0 OR coordinator_epoch = $5::bigint)
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
        ), op AS (
          INSERT INTO rust_coord.financial_operations (
            operation_key, job_id, op_type, amount_micro_usd,
            account_id, terminal_digest, billable_cap_micro_usd
          )
          SELECT $4, $2, 'resize_authorize', $3, $1, '', NULL FROM funds
          ON CONFLICT (operation_key) DO NOTHING
          RETURNING operation_key
        ), op_row AS (
          SELECT * FROM rust_coord.financial_operations WHERE operation_key = $4
        ), op_ok AS (
          SELECT 1 FROM op_row
          WHERE job_id = $2
            AND op_type = 'resize_authorize'
            AND amount_micro_usd = $3
            AND account_id = $1
            AND COALESCE(terminal_digest, '') = ''
            AND billable_cap_micro_usd IS NULL
        ), op_conflict AS (
          SELECT 1 FROM op_row WHERE NOT EXISTS (SELECT 1 FROM op_ok)
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
            AND EXISTS (SELECT 1 FROM op)
            AND EXISTS (SELECT 1 FROM op_ok)
            AND NOT EXISTS (SELECT 1 FROM op_conflict)
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
        ), cleanup_op AS (
          DELETE FROM rust_coord.financial_operations fo
          WHERE fo.operation_key = $4
            AND EXISTS (SELECT 1 FROM op)
            AND NOT EXISTS (SELECT 1 FROM mark)
          RETURNING fo.operation_key
        )
        SELECT
          (SELECT reserved_total_micro_usd FROM mark) AS reserved_total_micro_usd,
          (SELECT reserved_withdrawable_micro_usd FROM mark) AS reserved_withdrawable_micro_usd,
          EXISTS (SELECT 1 FROM op_conflict) AS param_conflict
        "#
    }

    /// The SQL that will back settle once SQLx is wired (mirrors MemoryLedger.settle).
    /// Parameters: $1 account, $2 job_id, $3 actual, $4 terminal_digest, $5 operation_key,
    ///             $6 attempt_id, $7 lease_id, $8 se_signature, $9 fencing_epoch
    /// Op claim gates digest + money (DECISIONS #32/#33): reused op keys cannot move funds.
    /// Digest/op inserts are gated on guard so failed settles cannot poison digests/op keys.
    /// Outbox insert gated on mark (DECISIONS #37/#38).
    /// Fencing epoch must match (or job unbound=0) — DECISIONS #52.
    pub fn settle_sql() -> &'static str {
        r#"
        WITH job AS (
          SELECT job_id, account_id, reserved_total_micro_usd AS reserved,
                 reserved_withdrawable_micro_usd AS reserved_wdr,
                 terminal_disposition, coordinator_epoch
          FROM rust_coord.inference_jobs
          WHERE job_id = $2
            AND account_id = $1
          FOR UPDATE
        ), guard AS (
          SELECT 1 FROM job
          WHERE terminal_disposition IS NULL
            AND state = 'start_authorized'
            AND $3::bigint >= 0
            AND $3::bigint <= reserved
            AND (coordinator_epoch = 0 OR coordinator_epoch = $9::bigint)
        ), op AS (
          INSERT INTO rust_coord.financial_operations (
            operation_key, job_id, op_type, amount_micro_usd,
            account_id, terminal_digest, billable_cap_micro_usd
          )
          SELECT $5, $2, 'settle', $3, $1, $4, NULL FROM guard
          ON CONFLICT (operation_key) DO NOTHING
          RETURNING operation_key
        ), op_row AS (
          SELECT * FROM rust_coord.financial_operations WHERE operation_key = $5
        ), op_ok AS (
          SELECT 1 FROM op_row
          WHERE job_id = $2
            AND op_type = 'settle'
            AND amount_micro_usd = $3
            AND account_id = $1
            AND COALESCE(terminal_digest, '') = COALESCE($4, '')
            AND billable_cap_micro_usd IS NULL
        ), op_conflict AS (
          SELECT 1 FROM op_row WHERE NOT EXISTS (SELECT 1 FROM op_ok)
        ), digest AS (
          INSERT INTO rust_coord.provider_terminals (
            terminal_digest, job_id, attempt_id, lease_id, se_signature, disposition
          )
          SELECT $4, $2, $6, $7, COALESCE($8, ''), 'settled'
          FROM guard
          WHERE EXISTS (SELECT 1 FROM op)
            AND EXISTS (SELECT 1 FROM op_ok)
            AND NOT EXISTS (SELECT 1 FROM op_conflict)
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
            AND EXISTS (SELECT 1 FROM op)
            AND EXISTS (SELECT 1 FROM op_ok)
            AND NOT EXISTS (SELECT 1 FROM op_conflict)
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
        ), outbox AS (
          INSERT INTO rust_coord.outbox (kind, payload, attempts)
          SELECT 'inference.settled',
                 jsonb_build_object(
                   'job_id', $2,
                   'attempt_id', $6,
                   'terminal_digest', $4,
                   'charged_micro_usd', $3
                 ),
                 0
          FROM mark
          RETURNING id
        ), cleanup_op AS (
          DELETE FROM rust_coord.financial_operations fo
          WHERE fo.operation_key = $5
            AND EXISTS (SELECT 1 FROM op)
            AND NOT EXISTS (SELECT 1 FROM digest)
          RETURNING fo.operation_key
        )
        SELECT
          (SELECT refund FROM credit) AS refund,
          (SELECT refund_wdr FROM credit) AS refund_wdr,
          EXISTS (SELECT 1 FROM op_conflict) AS param_conflict
        "#
    }

    /// Settle-capped SQL: charge = LEAST(actual, billable_cap, reserved) (DECISIONS #23).
    /// Parameters: $1 account, $2 job_id, $3 actual, $4 billable_cap, $5 terminal_digest,
    ///             $6 operation_key, $7 attempt_id, $8 lease_id, $9 se_signature, $10 fencing_epoch
    /// Op claim gates digest + money so reused op keys cannot move funds (DECISIONS #33).
    /// Outbox insert gated on mark (DECISIONS #37/#38).
    /// Fencing epoch must match (or job unbound=0) — DECISIONS #52.
    pub fn settle_capped_sql() -> &'static str {
        r#"
        WITH job AS (
          SELECT job_id, account_id, reserved_total_micro_usd AS reserved,
                 reserved_withdrawable_micro_usd AS reserved_wdr,
                 terminal_disposition, coordinator_epoch
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
            AND j.state = 'start_authorized'
            AND (j.coordinator_epoch = 0 OR j.coordinator_epoch = $10::bigint)
        ), op AS (
          INSERT INTO rust_coord.financial_operations (
            operation_key, job_id, op_type, amount_micro_usd,
            account_id, terminal_digest, billable_cap_micro_usd
          )
          SELECT $6, $2, 'settle_capped', c.amount, $1, $5, $4 FROM charge c
          ON CONFLICT (operation_key) DO NOTHING
          RETURNING operation_key
        ), op_row AS (
          SELECT * FROM rust_coord.financial_operations WHERE operation_key = $6
        ), op_ok AS (
          -- LEFT JOIN charge: disposed jobs have empty charge; still validate
          -- amount against LEAST(actual,cap,reserved) so mismatched replay
          -- conflicts (MemoryLedger parity — DECISIONS #151).
          SELECT 1 FROM op_row o
          LEFT JOIN charge c ON TRUE
          JOIN job j ON TRUE
          WHERE o.job_id = $2
            AND o.op_type = 'settle_capped'
            AND o.amount_micro_usd = COALESCE(
              c.amount,
              LEAST(GREATEST(0, $3::bigint), GREATEST(0, $4::bigint), j.reserved)
            )
            AND o.account_id = $1
            AND COALESCE(o.terminal_digest, '') = COALESCE($5, '')
            AND o.billable_cap_micro_usd IS NOT DISTINCT FROM $4::bigint
        ), op_conflict AS (
          SELECT 1 FROM op_row WHERE NOT EXISTS (SELECT 1 FROM op_ok)
        ), digest AS (
          INSERT INTO rust_coord.provider_terminals (
            terminal_digest, job_id, attempt_id, lease_id, se_signature, disposition
          )
          SELECT $5, $2, $7, $8, COALESCE($9, ''), 'settled'
          FROM charge
          WHERE EXISTS (SELECT 1 FROM op)
            AND EXISTS (SELECT 1 FROM op_ok)
            AND NOT EXISTS (SELECT 1 FROM op_conflict)
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
          WHERE EXISTS (SELECT 1 FROM op)
            AND EXISTS (SELECT 1 FROM op_ok)
            AND NOT EXISTS (SELECT 1 FROM op_conflict)
            AND EXISTS (SELECT 1 FROM digest)
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
        ), outbox AS (
          INSERT INTO rust_coord.outbox (kind, payload, attempts)
          SELECT 'inference.settled',
                 jsonb_build_object(
                   'job_id', $2,
                   'attempt_id', $7,
                   'terminal_digest', $5,
                   'charged_micro_usd', c.amount
                 ),
                 0
          FROM mark
          CROSS JOIN calc c
          RETURNING id
        ), cleanup_op AS (
          DELETE FROM rust_coord.financial_operations fo
          WHERE fo.operation_key = $6
            AND EXISTS (SELECT 1 FROM op)
            AND NOT EXISTS (SELECT 1 FROM digest)
          RETURNING fo.operation_key
        )
        SELECT
          (SELECT refund FROM credit) AS refund,
          (SELECT refund_wdr FROM credit) AS refund_wdr,
          (SELECT amount FROM credit) AS amount,
          EXISTS (SELECT 1 FROM op_conflict) AS param_conflict
        "#
    }

    /// Force-settle SQL for start_authorized held jobs (mirrors recovery::force_settle_held).
    /// Requires state = start_authorized and no terminal yet (DECISIONS #16/#17).
    /// Parameters: $1 account, $2 job_id, $3 actual, $4 terminal_digest, $5 operation_key,
    ///             $6 attempt_id, $7 lease_id, $8 se_signature, $9 fencing_epoch
    pub fn force_settle_sql() -> &'static str {
        r#"
        WITH job AS (
          SELECT job_id, account_id, reserved_total_micro_usd AS reserved,
                 reserved_withdrawable_micro_usd AS reserved_wdr,
                 terminal_disposition, state, coordinator_epoch
          FROM rust_coord.inference_jobs
          WHERE job_id = $2
            AND account_id = $1
          FOR UPDATE
        ), guard AS (
          SELECT 1 FROM job
          WHERE terminal_disposition IS NULL
            AND state = 'start_authorized'
            AND (coordinator_epoch = 0 OR coordinator_epoch = $9::bigint)
        ), charge AS (
          SELECT LEAST(GREATEST(0, $3::bigint), j.reserved) AS amount
          FROM job j
          WHERE EXISTS (SELECT 1 FROM guard)
        ), op AS (
          INSERT INTO rust_coord.financial_operations (
            operation_key, job_id, op_type, amount_micro_usd,
            account_id, terminal_digest, billable_cap_micro_usd
          )
          SELECT $5, $2, 'force_settle', c.amount, $1, $4, NULL FROM charge c
          ON CONFLICT (operation_key) DO NOTHING
          RETURNING operation_key
        ), op_row AS (
          SELECT * FROM rust_coord.financial_operations WHERE operation_key = $5
        ), op_ok AS (
          -- LEFT JOIN charge: disposed jobs have empty charge; still validate
          -- amount against LEAST(actual,reserved) (DECISIONS #151).
          SELECT 1 FROM op_row o
          LEFT JOIN charge c ON TRUE
          JOIN job j ON TRUE
          WHERE o.job_id = $2
            AND o.op_type = 'force_settle'
            AND o.amount_micro_usd = COALESCE(
              c.amount,
              LEAST(GREATEST(0, $3::bigint), j.reserved)
            )
            AND o.account_id = $1
            AND COALESCE(o.terminal_digest, '') = COALESCE($4, '')
            AND o.billable_cap_micro_usd IS NULL
        ), op_conflict AS (
          SELECT 1 FROM op_row WHERE NOT EXISTS (SELECT 1 FROM op_ok)
        ), digest AS (
          INSERT INTO rust_coord.provider_terminals (
            terminal_digest, job_id, attempt_id, lease_id, se_signature, disposition
          )
          SELECT $4, $2, $6, $7, COALESCE($8, ''), 'force_settled'
          FROM charge
          WHERE EXISTS (SELECT 1 FROM op)
            AND EXISTS (SELECT 1 FROM op_ok)
            AND NOT EXISTS (SELECT 1 FROM op_conflict)
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
          WHERE EXISTS (SELECT 1 FROM op)
            AND EXISTS (SELECT 1 FROM op_ok)
            AND NOT EXISTS (SELECT 1 FROM op_conflict)
            AND EXISTS (SELECT 1 FROM digest)
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
        ), outbox AS (
          INSERT INTO rust_coord.outbox (kind, payload, attempts)
          SELECT 'inference.settled',
                 jsonb_build_object(
                   'job_id', $2,
                   'attempt_id', $6,
                   'terminal_digest', $4,
                   'charged_micro_usd', c.amount,
                   'disposition', 'force_settled'
                 ),
                 0
          FROM mark
          CROSS JOIN calc c
          RETURNING id
        ), cleanup_op AS (
          DELETE FROM rust_coord.financial_operations fo
          WHERE fo.operation_key = $5
            AND EXISTS (SELECT 1 FROM op)
            AND NOT EXISTS (SELECT 1 FROM digest)
          RETURNING fo.operation_key
        )
        SELECT
          (SELECT refund FROM credit) AS refund,
          (SELECT refund_wdr FROM credit) AS refund_wdr,
          (SELECT amount FROM credit) AS amount,
          EXISTS (SELECT 1 FROM op_conflict) AS param_conflict
        "#
    }

    /// Release SQL for reserved-but-not-start_authorized jobs (mirrors MemoryLedger.release).
    /// Parameters: $1 account, $2 job_id, $3 operation_key, $4 fencing_epoch
    /// Op claim gates credit/mark so reused op keys cannot refund (DECISIONS #33).
    /// Fencing epoch must match (or job unbound=0) — DECISIONS #52.
    pub fn release_sql() -> &'static str {
        r#"
        WITH job AS (
          SELECT job_id, account_id, reserved_total_micro_usd AS reserved,
                 reserved_withdrawable_micro_usd AS reserved_wdr,
                 terminal_disposition, state, coordinator_epoch
          FROM rust_coord.inference_jobs
          WHERE job_id = $2
            AND account_id = $1
          FOR UPDATE
        ), guard AS (
          -- Forbidden after start_authorized (DECISIONS #16).
          SELECT 1 FROM job
          WHERE terminal_disposition IS NULL
            AND state <> 'start_authorized'
            AND (coordinator_epoch = 0 OR coordinator_epoch = $4::bigint)
        ), op AS (
          INSERT INTO rust_coord.financial_operations (
            operation_key, job_id, op_type, amount_micro_usd,
            account_id, terminal_digest, billable_cap_micro_usd
          )
          SELECT $3, $2, 'release', j.reserved, $1, '', NULL FROM job j
          WHERE EXISTS (SELECT 1 FROM guard)
          ON CONFLICT (operation_key) DO NOTHING
          RETURNING operation_key
        ), op_row AS (
          SELECT * FROM rust_coord.financial_operations WHERE operation_key = $3
        ), op_ok AS (
          SELECT 1 FROM op_row o
          JOIN job j ON TRUE
          WHERE o.job_id = $2
            AND o.op_type = 'release'
            AND o.amount_micro_usd = j.reserved
            AND o.account_id = $1
            AND COALESCE(o.terminal_digest, '') = ''
            AND o.billable_cap_micro_usd IS NULL
        ), op_conflict AS (
          SELECT 1 FROM op_row WHERE NOT EXISTS (SELECT 1 FROM op_ok)
        ), credit AS (
          UPDATE balances b
          SET balance_micro_usd = b.balance_micro_usd + j.reserved,
              withdrawable_micro_usd = b.withdrawable_micro_usd + j.reserved_wdr,
              updated_at = NOW()
          FROM job j
          WHERE b.account_id = $1
            AND EXISTS (SELECT 1 FROM guard)
            AND EXISTS (SELECT 1 FROM op)
            AND EXISTS (SELECT 1 FROM op_ok)
            AND NOT EXISTS (SELECT 1 FROM op_conflict)
          RETURNING j.reserved, j.reserved_wdr
        ), mark AS (
          UPDATE rust_coord.inference_jobs j
          SET state = 'released',
              terminal_disposition = 'released',
              updated_at = NOW()
          WHERE j.job_id = $2
            AND EXISTS (SELECT 1 FROM guard)
            AND EXISTS (SELECT 1 FROM op)
            AND EXISTS (SELECT 1 FROM op_ok)
            AND NOT EXISTS (SELECT 1 FROM op_conflict)
          RETURNING j.job_id, j.account_id
        ), outbox AS (
          -- Money refund + durable side effect commit together (DECISIONS #43).
          INSERT INTO rust_coord.outbox (kind, payload, attempts)
          SELECT 'inference.released',
                 jsonb_build_object(
                   'job_id', m.job_id,
                   'account', m.account_id,
                   'disposition', 'released',
                   'refunded_micro_usd', c.reserved
                 ),
                 0
          FROM mark m
          CROSS JOIN credit c
          WHERE EXISTS (SELECT 1 FROM mark)
          RETURNING id
        ), cleanup_op AS (
          DELETE FROM rust_coord.financial_operations fo
          WHERE fo.operation_key = $3
            AND EXISTS (SELECT 1 FROM op)
            AND NOT EXISTS (SELECT 1 FROM mark)
          RETURNING fo.operation_key
        )
        SELECT
          (SELECT reserved FROM credit) AS reserved,
          (SELECT reserved_wdr FROM credit) AS reserved_wdr,
          EXISTS (SELECT 1 FROM op_conflict) AS param_conflict
        "#
    }

    /// Rebind an active job's coordinator_epoch after ownership re-acquire (DECISIONS #66).
    /// Parameters: $1 job_id, $2 new_fencing_epoch, $3 holder (must match ownership row)
    pub fn adopt_fencing_epoch_sql() -> &'static str {
        r#"
        WITH own AS (
          SELECT 1 FROM rust_coord.coordinator_ownership
          WHERE holder = $3 AND fencing_epoch = $2::bigint
          FOR UPDATE
        ), job AS (
          SELECT job_id, coordinator_epoch AS prev_epoch, terminal_disposition
          FROM rust_coord.inference_jobs
          WHERE job_id = $1
          FOR UPDATE
        ), adopt AS (
          UPDATE rust_coord.inference_jobs j
          SET coordinator_epoch = $2::bigint
          FROM job
          WHERE j.job_id = job.job_id
            AND EXISTS (SELECT 1 FROM own)
            AND (job.terminal_disposition IS NULL OR job.terminal_disposition = '')
          RETURNING j.job_id, job.prev_epoch
        )
        SELECT job_id, prev_epoch FROM adopt
        "#
    }

    /// Bulk adopt: rebind all non-disposed jobs for the current holder (DECISIONS #72).
    /// Parameters: $1 new_fencing_epoch, $2 holder
    pub fn adopt_all_fencing_epoch_sql() -> &'static str {
        r#"
        WITH own AS (
          SELECT 1 FROM rust_coord.coordinator_ownership
          WHERE holder = $2 AND fencing_epoch = $1::bigint
          FOR UPDATE
        ), adopt AS (
          UPDATE rust_coord.inference_jobs j
          SET coordinator_epoch = $1::bigint
          WHERE EXISTS (SELECT 1 FROM own)
            AND (j.terminal_disposition IS NULL OR j.terminal_disposition = '')
          RETURNING j.job_id, j.coordinator_epoch
        )
        SELECT job_id, coordinator_epoch FROM adopt
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
        assert!(sql.contains("NOT EXISTS (SELECT 1 FROM existing)"));
        assert!(sql.contains("FROM job j"));
        assert!(sql.contains("'reserve'"));
        assert!(sql.contains("account_id"));
        assert!(sql.contains("terminal_digest"));
        assert!(sql.contains("billable_cap_micro_usd"));
        assert!(sql.contains("op_ok"));
        assert!(sql.contains("op_conflict"));
        assert!(sql.contains("param_conflict"));
        assert!(sql.contains("WHERE EXISTS (SELECT 1 FROM op)"));
        assert!(sql.contains("cleanup_op"));
        assert!(sql.contains("FROM eligible e"));
    }

    #[test]
    fn settle_sql_refunds_provenance_and_binds_terminal() {
        let sql = PostgresLedgerStub::settle_sql();
        assert!(sql.contains("rust_coord.inference_jobs"));
        assert!(sql.contains("rust_coord.provider_terminals"));
        assert!(sql.contains("financial_operations"));
        assert!(sql.contains("FOR UPDATE"));
        assert!(sql.contains("terminal_disposition"));
        assert!(sql.contains("state = 'start_authorized'"));
        assert!(sql.contains("refund_wdr"));
        assert!(sql.contains("'settle'"));
        assert!(sql.contains("account_id = $1"));
        assert!(sql.contains("SELECT $4, $2, $6, $7, COALESCE($8, ''), 'settled'"));
        assert!(sql.contains("lease_id"));
        assert!(sql.contains("se_signature"));
        assert!(sql.contains("FROM guard"));
        assert!(sql.contains("op_ok"));
        assert!(sql.contains("op_conflict"));
        assert!(sql.contains("param_conflict"));
        assert!(sql.contains("WHERE EXISTS (SELECT 1 FROM op)"));
        assert!(sql.contains("cleanup_op"));
        assert!(sql.contains("rust_coord.outbox"));
        assert!(sql.contains("inference.settled"));
        assert!(sql.contains("FROM mark"));
        assert!(sql.contains("coordinator_epoch = $9"));
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
        assert!(sql.contains("state = 'start_authorized'"));
        assert!(sql.contains("SELECT $5, $2, $7, $8, COALESCE($9, ''), 'settled'"));
        assert!(sql.contains("lease_id"));
        assert!(sql.contains("se_signature"));
        assert!(sql.contains("FROM charge"));
        assert!(sql.contains("op_ok"));
        assert!(sql.contains("op_conflict"));
        assert!(sql.contains("param_conflict"));
        assert!(sql.contains("billable_cap_micro_usd"));
        assert!(sql.contains("LEFT JOIN charge"));
        assert!(sql.contains("COALESCE("));
        assert!(sql.contains("WHERE EXISTS (SELECT 1 FROM op)"));
        assert!(sql.contains("cleanup_op"));
        assert!(sql.contains("rust_coord.outbox"));
        assert!(sql.contains("inference.settled"));
        assert!(sql.contains("coordinator_epoch = $10"));
    }

    #[test]
    fn settle_capped_and_force_settle_op_ok_tolerate_disposed_replay() {
        // DECISIONS #151: disposed jobs empty `charge`; op_ok must LEFT JOIN
        // so identical replay is not a false param_conflict.
        for sql in [
            PostgresLedgerStub::settle_capped_sql(),
            PostgresLedgerStub::force_settle_sql(),
        ] {
            assert!(
                sql.contains("LEFT JOIN charge"),
                "op_ok must LEFT JOIN charge for disposed-job replay"
            );
            assert!(
                sql.contains("COALESCE(") && sql.contains("c.amount"),
                "op_ok must COALESCE charge amount with LEAST(...) for disposed replay"
            );
        }
    }

    #[test]
    fn financial_op_param_bind_docs_cover_mismatch() {
        for sql in [
            PostgresLedgerStub::reserve_sql(),
            PostgresLedgerStub::settle_sql(),
            PostgresLedgerStub::settle_capped_sql(),
            PostgresLedgerStub::force_settle_sql(),
            PostgresLedgerStub::release_sql(),
            PostgresLedgerStub::mark_start_authorized_sql(),
            PostgresLedgerStub::resize_and_authorize_sql(),
        ] {
            assert!(
                sql.contains("op_conflict") && sql.contains("param_conflict"),
                "SQL must surface param_conflict for mismatched op-key reuse"
            );
            assert!(
                sql.contains("account_id") && sql.contains("terminal_digest"),
                "SQL must bind account_id + terminal_digest on financial_operations"
            );
        }
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
        assert!(sql.contains("SELECT $4, $2, $6, $7, COALESCE($8, ''), 'force_settled'"));
        assert!(sql.contains("lease_id"));
        assert!(sql.contains("se_signature"));
        assert!(sql.contains("FROM charge"));
        assert!(sql.contains("WHERE EXISTS (SELECT 1 FROM op)"));
        assert!(sql.contains("cleanup_op"));
        assert!(sql.contains("rust_coord.outbox"));
        assert!(sql.contains("inference.settled"));
        assert!(sql.contains("coordinator_epoch = $9"));
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
        assert!(sql.contains("EXISTS (SELECT 1 FROM op)"));
        assert!(sql.contains("cleanup_op"));
        assert!(sql.contains("rust_coord.outbox"));
        assert!(sql.contains("inference.released"));
        assert!(sql.contains("jsonb_build_object"));
        assert!(!sql.contains("json_build_object"));
        assert!(sql.contains("FROM mark m"));
        assert!(sql.contains("coordinator_epoch = $4"));
    }

    #[test]
    fn resize_and_authorize_sql_marks_start_authorized() {
        let sql = PostgresLedgerStub::resize_and_authorize_sql();
        assert!(sql.contains("rust_coord.inference_jobs"));
        assert!(sql.contains("start_authorized"));
        assert!(sql.contains("resize_authorize"));
        assert!(sql.contains("FOR UPDATE"));
        assert!(sql.contains("financial_operations"));
        assert!(sql.contains("account_id = $1"));
        assert!(sql.contains("'resize_authorize'"));
        assert!(sql.contains("op_ok"));
        assert!(sql.contains("param_conflict"));
        assert!(sql.contains("EXISTS (SELECT 1 FROM op)"));
        assert!(sql.contains("cleanup_op"));
        assert!(sql.contains("coordinator_epoch = $5"));
    }

    #[test]
    fn mark_start_authorized_sql_requires_reserved() {
        let sql = PostgresLedgerStub::mark_start_authorized_sql();
        assert!(sql.contains("rust_coord.inference_jobs"));
        assert!(sql.contains("start_authorized"));
        assert!(sql.contains("start_authorize"));
        assert!(sql.contains("state = 'reserved'"));
        assert!(sql.contains("FOR UPDATE"));
        assert!(sql.contains("account_id = $2"));
        assert!(sql.contains("'start_authorize'"));
        assert!(sql.contains("op_ok"));
        assert!(sql.contains("param_conflict"));
        assert!(sql.contains("EXISTS (SELECT 1 FROM op)"));
        assert!(sql.contains("cleanup_op"));
        assert!(sql.contains("coordinator_epoch = $4"));
    }

    #[test]
    fn adopt_fencing_epoch_sql_rebinds_active_job() {
        let sql = PostgresLedgerStub::adopt_fencing_epoch_sql();
        assert!(sql.contains("rust_coord.inference_jobs"));
        assert!(sql.contains("rust_coord.coordinator_ownership"));
        assert!(sql.contains("coordinator_epoch = $2"));
        assert!(sql.contains("holder = $3"));
        assert!(sql.contains("FOR UPDATE"));
        assert!(sql.contains("terminal_disposition IS NULL OR job.terminal_disposition = ''"));
        assert!(sql.contains("prev_epoch"));
        assert!(!sql.contains("balances"));
        assert!(!sql.contains("UPDATE balances"));
    }

    #[test]
    fn adopt_all_fencing_epoch_sql_bulk_rebinds() {
        let sql = PostgresLedgerStub::adopt_all_fencing_epoch_sql();
        assert!(sql.contains("rust_coord.inference_jobs"));
        assert!(sql.contains("rust_coord.coordinator_ownership"));
        assert!(sql.contains("coordinator_epoch = $1"));
        assert!(sql.contains("holder = $2"));
        assert!(sql.contains("FOR UPDATE"));
        assert!(sql.contains("terminal_disposition IS NULL"));
        assert!(!sql.contains("balances"));
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
