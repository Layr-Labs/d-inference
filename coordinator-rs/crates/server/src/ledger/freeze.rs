//! Resize + freeze + start authorization, and the running transition
//! (plan §12.4, §12.5).
//!
//! `resize_freeze` is one statement of data-modifying CTEs that atomically:
//!
//! 1. CASes the job (state IN reserved/preparing/prepared, locked version).
//! 2. Adjusts the reservation to the exact prepared hold: conceptually
//!    restores the old provenance, then re-reserves the new hold with fresh
//!    provenance from the restored balance — refund and additional debit are
//!    the same formula (plan §12.3; mirrors the smoke resize).
//! 3. Writes EVERY frozen term column (plan §12.4) and sets
//!    `start_authorized`; the schema CHECK forbids start authorization with
//!    unfrozen terms.
//! 4. Binds the attempt row to its prepared lease, recording the real wire
//!    fencing identity (session epoch, dispatch nonce, request digest) the
//!    request task carried on [`ResizeFreezeParams`] (plan §10.2).
//! 5. Records the `resize` financial operation with the full serialized
//!    [`FrozenTerms`] in its result — settlement re-reads the frozen rates
//!    from there, never from mutable pricing (plan §12.4).

use serde_json::Value;
use sqlx::Row;

use darkbloom_core::ids::JobId;
use darkbloom_core::money::MicroUsd;
use darkbloom_core::settlement::{
    self, ProviderClaimedUsage, ReservationProvenance, RoundingVersion, SettlementSplit,
};

use crate::contracts::{LedgerError, ResizeFreezeParams};

use super::error::{map_sqlx, with_retries, TxError};
use super::Ledger;

const RESIZE_SQL: &str = r"
WITH fence AS (
    SELECT fencing_epoch FROM rust_coord.coordinator_ownership
    WHERE id = 1 AND fencing_epoch = $4
    FOR SHARE
), existing AS (
    SELECT result FROM rust_coord.financial_operations WHERE operation_key = $1
), job_row AS (
    SELECT j.job_id, j.account_id, j.version,
           j.reserved_total_micro_usd AS old_total,
           j.reserved_withdrawable_micro_usd AS old_wd
    FROM rust_coord.inference_jobs j
    WHERE j.job_id = $2
      AND EXISTS (SELECT 1 FROM fence)
      AND NOT EXISTS (SELECT 1 FROM existing)
      AND j.state IN ('reserved','preparing','prepared')
    FOR UPDATE OF j
), bal AS (
    SELECT b.account_id,
           b.balance_micro_usd + jr.old_total AS restored_balance,
           b.withdrawable_micro_usd + jr.old_wd AS restored_wd
    FROM balances b
    JOIN job_row jr ON jr.account_id = b.account_id
    WHERE b.balance_micro_usd + jr.old_total >= $3
    FOR UPDATE OF b
), calc AS (
    SELECT bal.account_id, jr.version, jr.old_total, jr.old_wd,
           GREATEST(0, $3 - (bal.restored_balance - bal.restored_wd)) AS new_wd,
           bal.restored_balance - $3 AS balance_after,
           bal.restored_wd - GREATEST(0, $3 - (bal.restored_balance - bal.restored_wd)) AS wd_after
    FROM bal, job_row jr
), op AS (
    INSERT INTO rust_coord.financial_operations
        (operation_key, kind, job_id, account_id,
         amount_total_micro_usd, amount_withdrawable_micro_usd, result, coordinator_epoch)
    SELECT $1, 'resize', $2, c.account_id,
           c.old_total - $3, c.old_wd - c.new_wd,
           jsonb_build_object('state', 'start_authorized',
                              'new_hold', $3::BIGINT,
                              'reserved_withdrawable', c.new_wd,
                              'frozen', $5::JSONB),
           $4
    FROM calc c
    ON CONFLICT (operation_key) DO NOTHING
    RETURNING operation_key
), adjust AS (
    UPDATE balances b
    SET balance_micro_usd = c.balance_after,
        withdrawable_micro_usd = c.wd_after,
        updated_at = NOW()
    FROM calc c, op
    WHERE b.account_id = c.account_id
    RETURNING b.balance_micro_usd
), freeze_terms AS (
    UPDATE rust_coord.inference_jobs j
    SET reserved_total_micro_usd = $3,
        reserved_withdrawable_micro_usd = c.new_wd,
        concrete_model = $6,
        public_model = $7,
        pricing_version = $8,
        rounding_version = $9,
        billable_input_tokens = $10,
        bounded_output_tokens = $11,
        provider_stable_id = $12,
        beneficiary_account_id = $13,
        provider_payout_micro_usd = $14,
        platform_fee_micro_usd = $15,
        referral_beneficiary_account_id = $16,
        referral_share_ppm = $17,
        request_digest = $18,
        state = 'start_authorized',
        version = j.version + 1,
        updated_at = NOW()
    FROM calc c, op
    WHERE j.job_id = $2 AND j.version = c.version
    RETURNING j.job_id
), attempt AS (
    INSERT INTO rust_coord.inference_attempts AS a
        (attempt_id, job_id, provider_stable_id, session_epoch, coordinator_epoch,
         lease_id, dispatch_nonce, request_digest, state)
    SELECT $19, $2, $12, $22, $4, $20, $21, $18, 'prepared'
    FROM freeze_terms
    ON CONFLICT (attempt_id) DO UPDATE
    SET lease_id = EXCLUDED.lease_id, state = 'prepared', updated_at = NOW()
    WHERE a.state IN ('queued_to_socket','sent_unknown','prepared')
    RETURNING a.attempt_id
), adj_ledger AS (
    INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
    SELECT c.account_id,
           CASE WHEN c.old_total >= $3 THEN 'refund' ELSE 'charge' END,
           c.old_total - $3, a.balance_micro_usd, $2::TEXT
    FROM calc c, adjust a, op
    WHERE c.old_total <> $3
    RETURNING id
)
SELECT EXISTS (SELECT 1 FROM fence)      AS fence_ok,
       (SELECT e.result FROM existing e) AS existing_result,
       EXISTS (SELECT 1 FROM job_row)    AS job_ok,
       EXISTS (SELECT 1 FROM bal)        AS funds_ok,
       EXISTS (SELECT 1 FROM freeze_terms)     AS froze
";

pub(super) async fn resize_freeze(
    ledger: &Ledger,
    p: ResizeFreezeParams,
) -> Result<(), LedgerError> {
    if p.new_hold.is_negative() {
        return Err(LedgerError::Conflict("negative hold".to_owned()));
    }

    // Full-funded-bound split for the frozen absolute columns, computed by
    // darkbloom_core::settlement — never reimplemented here.
    let bound_split = full_bound_split(&p)?;

    let beneficiary = ledger
        .accounts
        .resolve(&ledger.pool, p.frozen.provider_beneficiary)
        .await?;
    let referral_account = match &p.frozen.referral {
        Some(referral) => Some(
            ledger
                .accounts
                .resolve(&ledger.pool, referral.beneficiary)
                .await?,
        ),
        None => None,
    };
    let referral_ppm: Option<i64> = p.frozen.referral.as_ref().map(|r| i64::from(r.share.get()));

    let frozen_json = serde_json::to_value(&p.frozen)
        .map_err(|e| LedgerError::Conflict(format!("frozen terms not serializable: {e}")))?;
    let epoch = i64::try_from(p.coordinator_epoch.get()).unwrap_or(i64::MAX);
    let session_epoch = i64::try_from(p.session_epoch.get()).unwrap_or(i64::MAX);
    let rounding = match p.frozen.rounding_version {
        RoundingVersion::CeilV1 => 1i64,
    };

    let row = with_retries(|| {
        let p = p.clone();
        let frozen_json = frozen_json.clone();
        let beneficiary = beneficiary.clone();
        let referral_account = referral_account.clone();
        let digest = p.request_digest.to_vec();
        let nonce = p.dispatch_nonce.to_vec();
        async move {
            sqlx::query(RESIZE_SQL)
                .bind(&p.operation_key)
                .bind(p.job.get())
                .bind(p.new_hold.get())
                .bind(epoch)
                .bind(&frozen_json)
                .bind(p.frozen.model.as_str())
                .bind(p.frozen.public_model.as_str())
                .bind(i64::from(p.frozen.pricing_version.0))
                .bind(rounding)
                .bind(i64::from(p.frozen.billable_input_tokens.get()))
                .bind(i64::from(p.frozen.max_output_tokens.get()))
                .bind(p.provider.get().to_string())
                .bind(&beneficiary)
                .bind(bound_split.provider_payout.get())
                .bind(bound_split.platform_fee.get())
                .bind(referral_account.as_deref())
                .bind(referral_ppm)
                .bind(&digest)
                .bind(p.attempt.get())
                .bind(p.lease.get())
                .bind(&nonce)
                .bind(session_epoch)
                .fetch_one(&ledger.pool)
                .await
                .map_err(TxError::from)
        }
    })
    .await?;

    let fence_ok: bool = row.try_get("fence_ok").map_err(map_sqlx)?;
    let existing: Option<Value> = row.try_get("existing_result").map_err(map_sqlx)?;
    let job_ok: bool = row.try_get("job_ok").map_err(map_sqlx)?;
    let funds_ok: bool = row.try_get("funds_ok").map_err(map_sqlx)?;
    let froze: bool = row.try_get("froze").map_err(map_sqlx)?;

    if !fence_ok {
        return Err(LedgerError::EpochFenced);
    }
    if existing.is_some() {
        return Ok(());
    }
    if !job_ok {
        return Err(state_conflict(ledger, p.job, "resize_freeze").await);
    }
    if !funds_ok {
        return Err(LedgerError::InsufficientFunds);
    }
    if froze {
        Ok(())
    } else {
        // Op raced with a concurrent identical resize; treat as replayed.
        let stored: Option<(Value,)> = sqlx::query_as(
            "SELECT result FROM rust_coord.financial_operations WHERE operation_key = $1",
        )
        .bind(&p.operation_key)
        .fetch_optional(&ledger.pool)
        .await
        .map_err(map_sqlx)?;
        if stored.is_some() {
            Ok(())
        } else {
            Err(LedgerError::Unavailable(
                "resize outcome ambiguous: operation key neither inserted nor found".to_owned(),
            ))
        }
    }
}

/// State CAS `start_authorized -> running` for the job plus
/// `prepared -> started` for its attempt (the partial unique index makes a
/// second started attempt per job a constraint violation, invariant 9.2.3).
pub(super) async fn mark_running(ledger: &Ledger, job: JobId) -> Result<(), LedgerError> {
    const SQL: &str = r"
WITH fence AS (
    SELECT 1 FROM rust_coord.coordinator_ownership
    WHERE id = 1 AND fencing_epoch = $2
    FOR SHARE
), upd AS (
    UPDATE rust_coord.inference_jobs j
    SET state = 'running', version = j.version + 1, updated_at = NOW()
    WHERE j.job_id = $1 AND j.state = 'start_authorized'
      AND EXISTS (SELECT 1 FROM fence)
    RETURNING j.job_id
), att AS (
    UPDATE rust_coord.inference_attempts a
    SET state = 'started', updated_at = NOW()
    FROM upd
    WHERE a.job_id = upd.job_id AND a.state = 'prepared'
    RETURNING a.attempt_id
)
SELECT EXISTS (SELECT 1 FROM fence) AS fence_ok,
       EXISTS (SELECT 1 FROM upd)   AS updated,
       (SELECT state FROM rust_coord.inference_jobs WHERE job_id = $1) AS state
";
    let epoch = ledger.current_epoch();
    let row = with_retries(|| async move {
        sqlx::query(SQL)
            .bind(job.get())
            .bind(epoch)
            .fetch_one(&ledger.pool)
            .await
            .map_err(TxError::from)
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
        Some("running") => Ok(()), // idempotent replay
        Some(other) => Err(LedgerError::Conflict(format!(
            "mark_running: job is '{other}', expected 'start_authorized'"
        ))),
        None => Err(LedgerError::Conflict(
            "mark_running: job not found".to_owned(),
        )),
    }
}

/// Full-bound settlement split used only for the frozen absolute columns
/// (`provider_payout_micro_usd`, `platform_fee_micro_usd` at the funded
/// bound). The exact rates settlement uses live in the serialized
/// [`darkbloom_core::settlement::FrozenTerms`] on the resize operation.
fn full_bound_split(p: &ResizeFreezeParams) -> Result<SettlementSplit, LedgerError> {
    let provenance = ReservationProvenance {
        total: p.new_hold,
        withdrawable: MicroUsd::ZERO,
    };
    let claimed = ProviderClaimedUsage {
        prompt_tokens: p.frozen.billable_input_tokens,
        completion_tokens: p.frozen.max_output_tokens,
    };
    let outcome = settlement::settle(&p.frozen, provenance, claimed, p.frozen.max_output_tokens)
        .map_err(|e| {
            LedgerError::Conflict(format!(
                "hold {} does not cover the funded bound charge: {e}",
                p.new_hold.get()
            ))
        })?;
    Ok(outcome.split)
}

async fn state_conflict(ledger: &Ledger, job: JobId, op: &str) -> LedgerError {
    let state: Option<(String,)> =
        sqlx::query_as("SELECT state FROM rust_coord.inference_jobs WHERE job_id = $1")
            .bind(job.get())
            .fetch_optional(&ledger.pool)
            .await
            .ok()
            .flatten();
    match state {
        Some((state,)) => LedgerError::Conflict(format!("{op}: job is '{state}'")),
        None => LedgerError::Conflict(format!("{op}: job not found")),
    }
}
