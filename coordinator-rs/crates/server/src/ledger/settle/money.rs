//! Settlement money movement: the operation record, consumer refund,
//! provider credit, authoritative fee rows, legacy projections, and the
//! job/attempt terminal writes (plan §12.6 steps 5–10).
//! Invariant: every row in here commits atomically with the settle
//! transaction that computed the charge — never partially.

use serde_json::{json, Value};
use sqlx::PgConnection;

use darkbloom_core::money::MicroUsd;
use darkbloom_core::settlement::{FrozenTerms, SettlementOutcome};

use crate::contracts::{LedgerError, SettleOutcome, SettleParams};
use crate::ledger::error::TxError;
use crate::ledger::Ledger;

use super::receipt::{
    reasoning_tokens, response_hash_bytes, set_receipt_disposition, terminal_outcome,
};
use super::transaction::JobRow;

/// Steps 5–10 of plan §12.6 once the charge is final: op record, consumer
/// refund, provider credit, fee allocations, legacy projections, attempt +
/// job terminal, outbox.
#[allow(clippy::too_many_lines)]
pub(super) async fn apply_settlement(
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

pub(super) fn result_json(outcome: &SettleOutcome) -> Value {
    json!({
        "charged": outcome.charged.get(),
        "refunded": outcome.refunded.get(),
        "provider_payout": outcome.provider_payout.get(),
        "flagged_for_review": outcome.flagged_for_review,
    })
}
