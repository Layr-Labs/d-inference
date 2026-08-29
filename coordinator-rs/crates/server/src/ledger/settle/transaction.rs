//! The settle transaction flow: epoch fence, replay check, job/attempt
//! locks, durable-state routing, and the frozen-terms recompute
//! (plan §12.6 steps 1–5).

use serde_json::Value;
use sqlx::{PgConnection, Row};

use darkbloom_core::money::{MicroUsd, Tokens};
use darkbloom_core::settlement::{self, FrozenTerms, ProviderClaimedUsage, ReservationProvenance};

use crate::contracts::{LedgerError, SettleOutcome, SettleParams};
use crate::ledger::error::TxError;
use crate::ledger::Ledger;

use super::money::apply_settlement;
use super::receipt::{replay_disposition, set_receipt_disposition, terminal_is_v1, upsert_receipt};
use super::review::park_job_for_review;

/// Job columns settlement needs, read under `FOR UPDATE`.
pub(super) struct JobRow {
    pub(super) state: String,
    pub(super) version: i64,
    pub(super) account_id: String,
    pub(super) api_key_id: String,
    pub(super) reserved_total: i64,
    pub(super) reserved_withdrawable: i64,
    pub(super) concrete_model: Option<String>,
    pub(super) public_model: Option<String>,
    pub(super) provider_stable_id: Option<String>,
    pub(super) beneficiary_account_id: Option<String>,
}

pub(super) fn zero_outcome(flagged: bool) -> SettleOutcome {
    SettleOutcome {
        charged: MicroUsd::ZERO,
        refunded: MicroUsd::ZERO,
        provider_payout: MicroUsd::ZERO,
        flagged_for_review: flagged,
    }
}

pub(super) async fn settle_tx(ledger: &Ledger, p: &SettleParams) -> Result<SettleOutcome, TxError> {
    let epoch = i64::try_from(p.coordinator_epoch.get()).unwrap_or(i64::MAX);
    let mut tx = ledger.pool.begin().await?;

    // 1. Epoch fence, held FOR SHARE for the duration of the transaction.
    let fence: Option<(i64,)> = sqlx::query_as(
        "SELECT fencing_epoch FROM rust_coord.coordinator_ownership \
         WHERE id = 1 AND fencing_epoch = $1 FOR SHARE",
    )
    .bind(epoch)
    .fetch_optional(&mut *tx)
    .await?;
    if fence.is_none() {
        return Err(LedgerError::EpochFenced.into());
    }

    // 2. Idempotent replay on the operation key (plan §9.3.2).
    if let Some((result,)) = fetch_op_result(&mut tx, &p.operation_key).await? {
        return Ok(outcome_from_result(&result));
    }

    // 3/4. Lock the job, then its attempt.
    let job = lock_job(&mut tx, p).await?;
    let attempt_state: Option<(String,)> = sqlx::query_as(
        "SELECT state FROM rust_coord.inference_attempts \
         WHERE attempt_id = $1 AND job_id = $2 FOR UPDATE",
    )
    .bind(p.attempt.get())
    .bind(p.job.get())
    .fetch_optional(&mut *tx)
    .await?;
    if attempt_state.is_none() {
        return Err(LedgerError::Conflict("settle: attempt not bound to job".to_owned()).into());
    }

    // Terminal receipt upsert: same digest replays, bumping received_count.
    let receipt = upsert_receipt(&mut tx, p, epoch).await?;
    if let Some(disposition) = receipt {
        let outcome = replay_disposition(&mut tx, p, &disposition).await?;
        tx.commit().await?; // persist the received_count bump
        return outcome.map_err(TxError::from);
    }

    // Same attempt, different digest: protocol conflict — durable conflict
    // record, provider review, NO money (plan §12.8, §18 "Terminal conflict").
    let (other_digests,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM rust_coord.provider_terminals \
         WHERE attempt_id = $1 AND terminal_digest <> $2",
    )
    .bind(p.attempt.get())
    .bind(&p.terminal_digest[..])
    .fetch_one(&mut *tx)
    .await?;
    if other_digests > 0 {
        sqlx::query(
            "UPDATE rust_coord.provider_terminals \
             SET conflict = TRUE, \
                 disposition = COALESCE(disposition, 'conflict'), \
                 disposition_at = COALESCE(disposition_at, NOW()), \
                 updated_at = NOW() \
             WHERE attempt_id = $1",
        )
        .bind(p.attempt.get())
        .execute(&mut *tx)
        .await?;
        park_job_for_review(&mut tx, p, &job, "terminal_digest_conflict").await?;
        tx.commit().await?;
        return Err(LedgerError::Conflict(
            "terminal digest conflict: same attempt, different digest — no money moved".to_owned(),
        )
        .into());
    }

    // Route on the durable job state (plan §12.2).
    match job.state.as_str() {
        "released" | "released_reviewed" => {
            // Late terminal after release: recorded, acknowledged, no money
            // (plan §12.7).
            set_receipt_disposition(&mut tx, p, "late").await?;
            tx.commit().await?;
            return Ok(zero_outcome(false));
        }
        "settled" | "settled_reviewed" => {
            // Settled by an earlier operation; this receipt is a duplicate.
            set_receipt_disposition(&mut tx, p, "duplicate").await?;
            let stored = fetch_settle_op_for_job(&mut tx, p).await?;
            tx.commit().await?;
            return Ok(stored.unwrap_or_else(|| zero_outcome(false)));
        }
        "review_pending" => {
            set_receipt_disposition(&mut tx, p, "review_pending").await?;
            tx.commit().await?;
            return Ok(zero_outcome(true));
        }
        "start_authorized" | "running" => {}
        other => {
            // A terminal for a job never authorized to start is a protocol
            // violation: park for review, move nothing.
            tracing::warn!(job = %p.job, state = other, "terminal before start authorization");
            set_receipt_disposition(&mut tx, p, "review_pending").await?;
            park_job_for_review(&mut tx, p, &job, "terminal_before_start_authorization").await?;
            tx.commit().await?;
            return Ok(zero_outcome(true));
        }
    }

    // Defense-in-depth on plan §12.6 step 3: money moves only on a terminal
    // whose SE signature the intake layer verified. The session is the
    // verifying layer (it holds the registered key); an unverified v2
    // terminal reaching this reducer parks the job in review instead of
    // paying. v1 terminals (`"protocol":"v1"` receipts) have no signed
    // canonical form and settle on transport trust, matching today's Go
    // behavior.
    if !p.signature_verified && !terminal_is_v1(&p.terminal_json) {
        tracing::warn!(job = %p.job, "unverified v2 terminal signature — parking for review");
        set_receipt_disposition(&mut tx, p, "review_pending").await?;
        park_job_for_review(&mut tx, p, &job, "terminal_signature_unverified").await?;
        tx.commit().await?;
        return Ok(zero_outcome(true));
    }

    // 5. Recompute the charge from the frozen terms (plan §12.4: settlement
    //    never re-reads mutable pricing).
    let Some(terms) = fetch_frozen_terms(&mut tx, p).await? else {
        set_receipt_disposition(&mut tx, p, "review_pending").await?;
        park_job_for_review(&mut tx, p, &job, "frozen_terms_missing").await?;
        tx.commit().await?;
        return Ok(zero_outcome(true));
    };
    let provenance = ReservationProvenance {
        total: MicroUsd::new(job.reserved_total),
        withdrawable: MicroUsd::new(job.reserved_withdrawable),
    };
    let claimed = ProviderClaimedUsage {
        prompt_tokens: tokens_sat(p.prompt_tokens),
        completion_tokens: tokens_sat(p.completion_tokens_claimed),
    };
    let accepted = tokens_sat(p.accepted_cumulative_tokens);

    let outcome = match settlement::settle(&terms, provenance, claimed, accepted) {
        Ok(outcome) if outcome.needs_review() => {
            let reason = format!("usage_review:{:?}", outcome.review_flags);
            set_receipt_disposition(&mut tx, p, "review_pending").await?;
            park_job_for_review(&mut tx, p, &job, &reason).await?;
            tx.commit().await?;
            return Ok(zero_outcome(true));
        }
        Ok(outcome) => outcome,
        Err(err) => {
            set_receipt_disposition(&mut tx, p, "review_pending").await?;
            park_job_for_review(&mut tx, p, &job, &format!("settlement_error:{err}")).await?;
            tx.commit().await?;
            return Ok(zero_outcome(true));
        }
    };

    // 6–10. Move the money and write every projection.
    let result = apply_settlement(&mut tx, ledger, p, &job, &terms, &outcome, epoch).await?;
    tx.commit().await?;
    Ok(result)
}

async fn lock_job(tx: &mut PgConnection, p: &SettleParams) -> Result<JobRow, TxError> {
    let row = sqlx::query(
        "SELECT state, version, account_id, api_key_id, \
                reserved_total_micro_usd, reserved_withdrawable_micro_usd, \
                concrete_model, public_model, provider_stable_id, beneficiary_account_id \
         FROM rust_coord.inference_jobs WHERE job_id = $1 FOR UPDATE",
    )
    .bind(p.job.get())
    .fetch_optional(&mut *tx)
    .await?
    .ok_or_else(|| LedgerError::Conflict("settle: job not found".to_owned()))?;

    Ok(JobRow {
        state: row.try_get("state")?,
        version: row.try_get("version")?,
        account_id: row.try_get("account_id")?,
        api_key_id: row.try_get("api_key_id")?,
        reserved_total: row.try_get("reserved_total_micro_usd")?,
        reserved_withdrawable: row.try_get("reserved_withdrawable_micro_usd")?,
        concrete_model: row.try_get("concrete_model")?,
        public_model: row.try_get("public_model")?,
        provider_stable_id: row.try_get("provider_stable_id")?,
        beneficiary_account_id: row.try_get("beneficiary_account_id")?,
    })
}

async fn fetch_op_result(
    tx: &mut PgConnection,
    operation_key: &str,
) -> Result<Option<(Value,)>, TxError> {
    Ok(sqlx::query_as(
        "SELECT result FROM rust_coord.financial_operations WHERE operation_key = $1",
    )
    .bind(operation_key)
    .fetch_optional(&mut *tx)
    .await?)
}

/// The settle operation for a job (any key): used when replaying a terminal
/// through a DIFFERENT operation key than the one that settled it.
pub(super) async fn fetch_settle_op_for_job(
    tx: &mut PgConnection,
    p: &SettleParams,
) -> Result<Option<SettleOutcome>, TxError> {
    let stored: Option<(Value,)> = sqlx::query_as(
        "SELECT result FROM rust_coord.financial_operations \
         WHERE job_id = $1 AND kind = 'settle' ORDER BY created_at LIMIT 1",
    )
    .bind(p.job.get())
    .fetch_optional(&mut *tx)
    .await?;
    Ok(stored.map(|(result,)| outcome_from_result(&result)))
}

/// Frozen terms are the authoritative rates, stored verbatim on the resize
/// operation (plan §12.4).
async fn fetch_frozen_terms(
    tx: &mut PgConnection,
    p: &SettleParams,
) -> Result<Option<FrozenTerms>, TxError> {
    let stored: Option<(Value,)> = sqlx::query_as(
        "SELECT result -> 'frozen' FROM rust_coord.financial_operations \
         WHERE job_id = $1 AND kind = 'resize' ORDER BY created_at LIMIT 1",
    )
    .bind(p.job.get())
    .fetch_optional(&mut *tx)
    .await?;
    match stored {
        Some((value,)) if !value.is_null() => match serde_json::from_value::<FrozenTerms>(value) {
            Ok(terms) => Ok(Some(terms)),
            Err(err) => {
                tracing::error!(job = %p.job, error = %err, "stored frozen terms undecodable");
                Ok(None)
            }
        },
        _ => Ok(None),
    }
}

pub(super) fn outcome_from_result(result: &Value) -> SettleOutcome {
    SettleOutcome {
        charged: MicroUsd::new(result.get("charged").and_then(Value::as_i64).unwrap_or(0)),
        refunded: MicroUsd::new(result.get("refunded").and_then(Value::as_i64).unwrap_or(0)),
        provider_payout: MicroUsd::new(
            result
                .get("provider_payout")
                .and_then(Value::as_i64)
                .unwrap_or(0),
        ),
        flagged_for_review: result
            .get("flagged_for_review")
            .and_then(Value::as_bool)
            .unwrap_or(false),
    }
}

fn tokens_sat(v: u64) -> Tokens {
    Tokens::new(u32::try_from(v).unwrap_or(u32::MAX))
}
