//! The settlement transaction (plan §12.6 steps 1–10, §12.8, §10.6).
//!
//! One `READ COMMITTED` transaction:
//!
//! 1.  Epoch fence (`FOR SHARE` on the ownership row, plan §20).
//! 2.  Operation-key replay check (plan §9.3.2).
//! 3.  Insert/validate the signed terminal receipt: the same
//!     `(attempt, digest)` replays the stored disposition; the same attempt
//!     with a DIFFERENT digest marks every receipt of the attempt as a
//!     conflict, moves the job to review, and moves NO money (plan §12.8).
//! 4.  Locks the job and attempt (`SELECT … FOR UPDATE`), then affected
//!     balance rows in deterministic account-id order.
//! 5.  Recomputes the charge with [`darkbloom_core::settlement::settle`]
//!     from the frozen terms stored on the `resize` operation — billable
//!     completion is `min(claimed, accepted checkpoint, funded bound)`.
//! 6.  Any review flag parks the job in `review_pending` WITHOUT moving
//!     money: the reservation stays debited until an explicit reviewed
//!     disposition (plan §12.2 — `review_pending` is nonterminal and
//!     retains its reservation).
//! 7.  Otherwise: consumer refund + provider credit (synchronous row
//!     updates), authoritative `fee_allocations` inserts (projected = FALSE;
//!     the bounded single-writer projection folds them in later, plan
//!     §12.6), legacy usage/earnings/ledger projections, attempt + job
//!     terminal, and an analytics outbox row — all committed together.

use serde_json::{json, Value};
use sqlx::{PgConnection, Row};

use darkbloom_core::money::{MicroUsd, Tokens};
use darkbloom_core::settlement::{
    self, FrozenTerms, ProviderClaimedUsage, ReservationProvenance, SettlementOutcome,
};

use crate::contracts::{LedgerError, SettleOutcome, SettleParams};

use super::error::{with_retries, TxError};
use super::Ledger;

/// Job columns settlement needs, read under `FOR UPDATE`.
struct JobRow {
    state: String,
    version: i64,
    account_id: String,
    api_key_id: String,
    reserved_total: i64,
    reserved_withdrawable: i64,
    concrete_model: Option<String>,
    public_model: Option<String>,
    provider_stable_id: Option<String>,
    beneficiary_account_id: Option<String>,
}

fn zero_outcome(flagged: bool) -> SettleOutcome {
    SettleOutcome {
        charged: MicroUsd::ZERO,
        refunded: MicroUsd::ZERO,
        provider_payout: MicroUsd::ZERO,
        flagged_for_review: flagged,
    }
}

pub(super) async fn settle(ledger: &Ledger, p: SettleParams) -> Result<SettleOutcome, LedgerError> {
    with_retries(|| {
        let p = p.clone();
        async move { settle_tx(ledger, &p).await }
    })
    .await
}

async fn settle_tx(ledger: &Ledger, p: &SettleParams) -> Result<SettleOutcome, TxError> {
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

/// Steps 5–10 of plan §12.6 once the charge is final: op record, consumer
/// refund, provider credit, fee allocations, legacy projections, attempt +
/// job terminal, outbox.
#[allow(clippy::too_many_lines)]
async fn apply_settlement(
    tx: &mut PgConnection,
    ledger: &Ledger,
    p: &SettleParams,
    job: &JobRow,
    terms: &FrozenTerms,
    outcome: &SettlementOutcome,
    epoch: i64,
) -> Result<SettleOutcome, TxError> {
    let charged = outcome.split.consumer_charge;
    let payout = outcome.split.provider_payout;
    let platform_fee = outcome.split.platform_fee;
    let referral_reward = outcome.split.referral_reward;
    let refund_total = outcome.refund_total;
    let refund_withdrawable = outcome.refund_withdrawable;

    let beneficiary = job
        .beneficiary_account_id
        .clone()
        .ok_or_else(|| LedgerError::Conflict("settle: beneficiary not frozen".to_owned()))?;
    let provider_stable = job
        .provider_stable_id
        .clone()
        .ok_or_else(|| LedgerError::Conflict("settle: provider not frozen".to_owned()))?;
    let concrete_model = job.concrete_model.clone().unwrap_or_default();
    let public_model = job.public_model.clone().unwrap_or_default();

    let settle_result = SettleOutcome {
        charged,
        refunded: refund_total,
        provider_payout: payout,
        flagged_for_review: false,
    };

    // Operation record: amounts are the consumer-side deltas (refund),
    // matching the smoke shape so §26.3 reconciliation sums to -charge.
    sqlx::query(
        "INSERT INTO rust_coord.financial_operations \
             (operation_key, kind, job_id, account_id, \
              amount_total_micro_usd, amount_withdrawable_micro_usd, result, coordinator_epoch) \
         VALUES ($1, 'settle', $2, $3, $4, $5, $6, $7)",
    )
    .bind(&p.operation_key)
    .bind(p.job.get())
    .bind(&job.account_id)
    .bind(refund_total.get())
    .bind(refund_withdrawable.get())
    .bind(result_json(&settle_result))
    .bind(epoch)
    .execute(&mut *tx)
    .await?;

    // Balance mutations in deterministic account-id order (plan §12.6).
    let consumer_first = job.account_id <= beneficiary;
    let (consumer_after, provider_after) = if consumer_first {
        let c = refund_consumer(tx, job, refund_total, refund_withdrawable).await?;
        let b = credit_provider(tx, &beneficiary, payout).await?;
        (c, b)
    } else {
        let b = credit_provider(tx, &beneficiary, payout).await?;
        let c = refund_consumer(tx, job, refund_total, refund_withdrawable).await?;
        (c, b)
    };

    // Authoritative fee rows — inserted, NOT folded into materialized
    // balances here (plan §12.6: the projection worker does that).
    if !platform_fee.is_zero() {
        insert_fee(
            tx,
            p,
            &ledger.platform_account,
            "platform",
            platform_fee,
            epoch,
        )
        .await?;
    }
    if !referral_reward.is_zero() {
        if let Some(referral) = &terms.referral {
            let referrer = ledger
                .accounts
                .resolve(&ledger.pool, referral.beneficiary)
                .await;
            match referrer {
                Ok(referrer) => {
                    insert_fee(tx, p, &referrer, "referral", referral_reward, epoch).await?;
                }
                Err(err) => {
                    // The frozen job row still carries the referral account;
                    // fall back to it rather than dropping the allocation.
                    let (frozen_referrer,): (Option<String>,) = sqlx::query_as(
                        "SELECT referral_beneficiary_account_id \
                         FROM rust_coord.inference_jobs WHERE job_id = $1",
                    )
                    .bind(p.job.get())
                    .fetch_one(&mut *tx)
                    .await?;
                    match frozen_referrer {
                        Some(referrer) => {
                            insert_fee(tx, p, &referrer, "referral", referral_reward, epoch)
                                .await?;
                        }
                        None => return Err(TxError::from(err)),
                    }
                }
            }
        }
    }

    // Legacy projections (plan §12.1): usage, totals, earnings, summaries.
    sqlx::query(
        "INSERT INTO usage \
             (provider_id, consumer_key_hash, key_id, model, public_model, \
              prompt_tokens, completion_tokens, request_id, cost_micro_usd) \
         VALUES ($1, '', $2, $3, $4, $5, $6, $7, $8)",
    )
    .bind(&provider_stable)
    .bind(&job.api_key_id)
    .bind(&concrete_model)
    .bind(&public_model)
    .bind(i64::from(outcome.billed_prompt_tokens.get()))
    .bind(i64::from(outcome.billed_completion_tokens.get()))
    .bind(p.job.get().to_string())
    .bind(charged.get())
    .execute(&mut *tx)
    .await?;

    sqlx::query(
        "INSERT INTO usage_totals (id, total_requests, total_prompt_tokens, total_completion_tokens) \
         VALUES (1, 1, $1, $2) \
         ON CONFLICT (id) DO UPDATE \
         SET total_requests = usage_totals.total_requests + 1, \
             total_prompt_tokens = usage_totals.total_prompt_tokens + $1, \
             total_completion_tokens = usage_totals.total_completion_tokens + $2",
    )
    .bind(i64::from(outcome.billed_prompt_tokens.get()))
    .bind(i64::from(outcome.billed_completion_tokens.get()))
    .execute(&mut *tx)
    .await?;

    let earning_inserted = sqlx::query(
        "INSERT INTO provider_earnings \
             (account_id, provider_id, provider_key, job_id, model, \
              amount_micro_usd, prompt_tokens, completion_tokens) \
         VALUES ($1, $2, $2, $3, $4, $5, $6, $7) \
         ON CONFLICT (job_id) WHERE job_id <> '' DO NOTHING",
    )
    .bind(&beneficiary)
    .bind(&provider_stable)
    .bind(p.job.get().to_string())
    .bind(&concrete_model)
    .bind(payout.get())
    .bind(i64::from(outcome.billed_prompt_tokens.get()))
    .bind(i64::from(outcome.billed_completion_tokens.get()))
    .execute(&mut *tx)
    .await?
    .rows_affected();

    if earning_inserted > 0 {
        for (key, key_type) in [(&beneficiary, "account"), (&provider_stable, "provider")] {
            sqlx::query(
                "INSERT INTO earnings_summary \
                     (key, key_type, total_count, total_micro_usd, \
                      total_prompt_tokens, total_completion_tokens) \
                 VALUES ($1, $2, 1, $3, $4, $5) \
                 ON CONFLICT (key, key_type) DO UPDATE \
                 SET total_count = earnings_summary.total_count + 1, \
                     total_micro_usd = earnings_summary.total_micro_usd + $3, \
                     total_prompt_tokens = earnings_summary.total_prompt_tokens + $4, \
                     total_completion_tokens = earnings_summary.total_completion_tokens + $5, \
                     updated_at = NOW()",
            )
            .bind(key)
            .bind(key_type)
            .bind(payout.get())
            .bind(i64::from(outcome.billed_prompt_tokens.get()))
            .bind(i64::from(outcome.billed_completion_tokens.get()))
            .execute(&mut *tx)
            .await?;
        }
    }

    if !refund_total.is_zero() {
        insert_ledger_entry(
            tx,
            &job.account_id,
            "refund",
            refund_total,
            consumer_after,
            p,
        )
        .await?;
    }
    if !payout.is_zero() {
        insert_ledger_entry(tx, &beneficiary, "payout", payout, provider_after, p).await?;
    }

    // Terminal disposition + attempt + job terminal (plan §12.6 step 8).
    set_receipt_disposition(tx, p, "settled").await?;
    sqlx::query(
        "UPDATE rust_coord.inference_attempts \
         SET state = 'terminal_recorded', updated_at = NOW() \
         WHERE attempt_id = $1 AND state IN ('prepared','started')",
    )
    .bind(p.attempt.get())
    .execute(&mut *tx)
    .await?;

    let (outcome_str, error_class) = terminal_outcome(&p.terminal_json);
    let updated = sqlx::query(
        "UPDATE rust_coord.inference_jobs j \
         SET state = 'settled', outcome = $2, error_class = $3, \
             usage_prompt_tokens = $4, usage_completion_tokens = $5, \
             usage_reasoning_tokens = $6, response_hash = $7, \
             accepted_chunk_seq = $8, accepted_cumulative_tokens = $9, \
             version = j.version + 1, updated_at = NOW() \
         WHERE j.job_id = $1 AND j.version = $10",
    )
    .bind(p.job.get())
    .bind(&outcome_str)
    .bind(&error_class)
    .bind(i64::from(outcome.billed_prompt_tokens.get()))
    .bind(i64::from(outcome.billed_completion_tokens.get()))
    .bind(reasoning_tokens(&p.terminal_json))
    .bind(response_hash_bytes(p))
    .bind(i64::try_from(p.accepted_sequence).unwrap_or(i64::MAX))
    .bind(i64::try_from(p.accepted_cumulative_tokens).unwrap_or(i64::MAX))
    .bind(job.version)
    .execute(&mut *tx)
    .await?
    .rows_affected();
    if updated == 0 {
        // The FOR UPDATE lock makes this unreachable; guard anyway so a
        // logic error can never commit a half-settlement.
        return Err(LedgerError::Conflict("settle: job version CAS failed".to_owned()).into());
    }

    // Non-critical analytics via the outbox (plan §12.6 step 9).
    sqlx::query(
        "INSERT INTO rust_coord.outbox (kind, payload, coordinator_epoch) VALUES ($1, $2, $3)",
    )
    .bind("settlement.analytics")
    .bind(json!({
        "job_id": p.job.get().to_string(),
        "attempt_id": p.attempt.get().to_string(),
        "charged_micro_usd": charged.get(),
        "provider_payout_micro_usd": payout.get(),
        "platform_fee_micro_usd": platform_fee.get(),
        "referral_reward_micro_usd": referral_reward.get(),
        "model": concrete_model,
    }))
    .bind(epoch)
    .execute(&mut *tx)
    .await?;

    Ok(settle_result)
}

async fn refund_consumer(
    tx: &mut PgConnection,
    job: &JobRow,
    refund_total: MicroUsd,
    refund_withdrawable: MicroUsd,
) -> Result<i64, TxError> {
    if refund_total.is_zero() && refund_withdrawable.is_zero() {
        let (balance,): (i64,) =
            sqlx::query_as("SELECT balance_micro_usd FROM balances WHERE account_id = $1")
                .bind(&job.account_id)
                .fetch_one(&mut *tx)
                .await?;
        return Ok(balance);
    }
    let (balance,): (i64,) = sqlx::query_as(
        "UPDATE balances \
         SET balance_micro_usd = balance_micro_usd + $2, \
             withdrawable_micro_usd = withdrawable_micro_usd + $3, \
             updated_at = NOW() \
         WHERE account_id = $1 \
         RETURNING balance_micro_usd",
    )
    .bind(&job.account_id)
    .bind(refund_total.get())
    .bind(refund_withdrawable.get())
    .fetch_one(&mut *tx)
    .await?;
    Ok(balance)
}

/// Provider earnings restore total AND withdrawable (plan §12.11 credit
/// semantics: provider and referral earnings are withdrawable).
async fn credit_provider(
    tx: &mut PgConnection,
    beneficiary: &str,
    payout: MicroUsd,
) -> Result<i64, TxError> {
    let (balance,): (i64,) = sqlx::query_as(
        "INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd) \
         VALUES ($1, $2, $2) \
         ON CONFLICT (account_id) DO UPDATE \
         SET balance_micro_usd = balances.balance_micro_usd + $2, \
             withdrawable_micro_usd = balances.withdrawable_micro_usd + $2, \
             updated_at = NOW() \
         RETURNING balance_micro_usd",
    )
    .bind(beneficiary)
    .bind(payout.get())
    .fetch_one(&mut *tx)
    .await?;
    Ok(balance)
}

async fn insert_fee(
    tx: &mut PgConnection,
    p: &SettleParams,
    beneficiary: &str,
    kind: &str,
    amount: MicroUsd,
    epoch: i64,
) -> Result<(), TxError> {
    sqlx::query(
        "INSERT INTO rust_coord.fee_allocations \
             (job_id, beneficiary_account_id, kind, amount_micro_usd, coordinator_epoch) \
         VALUES ($1, $2, $3, $4, $5) \
         ON CONFLICT (job_id, kind) DO NOTHING",
    )
    .bind(p.job.get())
    .bind(beneficiary)
    .bind(kind)
    .bind(amount.get())
    .bind(epoch)
    .execute(&mut *tx)
    .await?;
    Ok(())
}

async fn insert_ledger_entry(
    tx: &mut PgConnection,
    account: &str,
    entry_type: &str,
    amount: MicroUsd,
    balance_after: i64,
    p: &SettleParams,
) -> Result<(), TxError> {
    sqlx::query(
        "INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference) \
         VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(account)
    .bind(entry_type)
    .bind(amount.get())
    .bind(balance_after)
    .bind(p.job.get().to_string())
    .execute(&mut *tx)
    .await?;
    Ok(())
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

/// Inserts the receipt or bumps `received_count` on the same digest.
/// Returns `Some(disposition)` when a replayed receipt already has one.
async fn upsert_receipt(
    tx: &mut PgConnection,
    p: &SettleParams,
    epoch: i64,
) -> Result<Option<String>, TxError> {
    let (outcome_str, error_class) = terminal_outcome(&p.terminal_json);
    let row = sqlx::query(
        "INSERT INTO rust_coord.provider_terminals AS t \
             (attempt_id, terminal_digest, raw_terminal, outcome, error_class, \
              prompt_tokens, completion_tokens, reasoning_tokens, response_hash, \
              final_generated_tokens, rolling_hash_checkpoint, provider_signature, \
              origin_session_epoch, coordinator_epoch) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NULL, $11, $12, $13) \
         ON CONFLICT (attempt_id, terminal_digest) DO UPDATE \
         SET received_count = t.received_count + 1, \
             updated_at = NOW() \
         RETURNING t.disposition",
    )
    .bind(p.attempt.get())
    .bind(&p.terminal_digest[..])
    .bind(&p.terminal_json)
    .bind(&outcome_str)
    .bind(&error_class)
    .bind(i64::try_from(p.prompt_tokens).unwrap_or(i64::MAX))
    .bind(i64::try_from(p.completion_tokens_claimed).unwrap_or(i64::MAX))
    .bind(reasoning_tokens(&p.terminal_json))
    .bind(response_hash_bytes(p))
    .bind(i64::try_from(p.completion_tokens_claimed).unwrap_or(i64::MAX))
    .bind(signature_bytes(&p.terminal_json))
    .bind(i64::try_from(p.origin_session_epoch.get()).unwrap_or(i64::MAX))
    .bind(epoch)
    .fetch_one(&mut *tx)
    .await?;
    let disposition: Option<String> = row.try_get("disposition")?;
    Ok(disposition)
}

/// Same-digest replay: return the disposition recorded by the earlier
/// settlement (plan §12.8).
async fn replay_disposition(
    tx: &mut PgConnection,
    p: &SettleParams,
    disposition: &str,
) -> Result<Result<SettleOutcome, LedgerError>, TxError> {
    match disposition {
        "settled" | "duplicate" => {
            let stored = fetch_settle_op_for_job(tx, p).await?;
            Ok(Ok(stored.unwrap_or_else(|| zero_outcome(false))))
        }
        "review_pending" => Ok(Ok(zero_outcome(true))),
        "late" => Ok(Ok(zero_outcome(false))),
        other => Ok(Err(LedgerError::Conflict(format!(
            "terminal receipt disposition '{other}' — no money moved"
        )))),
    }
}

async fn set_receipt_disposition(
    tx: &mut PgConnection,
    p: &SettleParams,
    disposition: &str,
) -> Result<(), TxError> {
    sqlx::query(
        "UPDATE rust_coord.provider_terminals \
         SET disposition = $3, disposition_at = NOW(), updated_at = NOW() \
         WHERE attempt_id = $1 AND terminal_digest = $2 AND disposition IS NULL",
    )
    .bind(p.attempt.get())
    .bind(&p.terminal_digest[..])
    .bind(disposition)
    .execute(&mut *tx)
    .await?;
    Ok(())
}

/// Parks a non-terminal job in `review_pending` (nonterminal, reservation
/// retained — plan §12.2) with the reason recorded.
async fn park_job_for_review(
    tx: &mut PgConnection,
    p: &SettleParams,
    job: &JobRow,
    reason: &str,
) -> Result<(), TxError> {
    sqlx::query(
        "UPDATE rust_coord.inference_jobs j \
         SET state = 'review_pending', error_class = $2, \
             version = j.version + 1, updated_at = NOW() \
         WHERE j.job_id = $1 AND j.version = $3 \
           AND j.state IN ('reserved','preparing','prepared','start_authorized','running')",
    )
    .bind(p.job.get())
    .bind(reason)
    .bind(job.version)
    .execute(&mut *tx)
    .await?;
    Ok(())
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
async fn fetch_settle_op_for_job(
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

fn result_json(outcome: &SettleOutcome) -> Value {
    json!({
        "charged": outcome.charged.get(),
        "refunded": outcome.refunded.get(),
        "provider_payout": outcome.provider_payout.get(),
        "flagged_for_review": outcome.flagged_for_review,
    })
}

fn outcome_from_result(result: &Value) -> SettleOutcome {
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

fn terminal_outcome(terminal: &Value) -> (String, Option<String>) {
    let outcome = terminal
        .get("outcome")
        .and_then(Value::as_str)
        .unwrap_or("completed")
        .to_owned();
    let error_class = terminal
        .get("error_class")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    (outcome, error_class)
}

fn reasoning_tokens(terminal: &Value) -> i64 {
    terminal
        .get("reasoning_tokens")
        .and_then(Value::as_i64)
        .unwrap_or(0)
        .max(0)
}

fn response_hash_bytes(p: &SettleParams) -> Vec<u8> {
    p.terminal_json
        .get("response_hash")
        .and_then(Value::as_str)
        .map(|s| s.as_bytes().to_vec())
        .unwrap_or_else(|| p.terminal_digest.to_vec())
}

fn signature_bytes(terminal: &Value) -> Vec<u8> {
    terminal
        .get("provider_signature")
        .or_else(|| terminal.get("signature"))
        .and_then(Value::as_str)
        .map(|s| s.as_bytes().to_vec())
        .unwrap_or_default()
}
