//! Terminal receipt intake: upsert/dedup on `(attempt, digest)`, replayed
//! dispositions, and the receipt field extractors (plan §12.8).

use serde_json::Value;
use sqlx::{PgConnection, Row};

use crate::contracts::{LedgerError, SettleOutcome, SettleParams};
use crate::ledger::error::TxError;

use super::transaction::{fetch_settle_op_for_job, zero_outcome};

/// Inserts the receipt or bumps `received_count` on the same digest.
/// Returns `Some(disposition)` when a replayed receipt already has one.
pub(super) async fn upsert_receipt(
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
pub(super) async fn replay_disposition(
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

pub(super) async fn set_receipt_disposition(
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

/// True for the coordinator-built v1 receipt shape
/// (`request_task::terminal::TerminalReceipt::V1{,Error}::to_json`).
pub(super) fn terminal_is_v1(terminal: &Value) -> bool {
    terminal.get("protocol").and_then(Value::as_str) == Some("v1")
}

pub(super) fn terminal_outcome(terminal: &Value) -> (String, Option<String>) {
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

pub(super) fn reasoning_tokens(terminal: &Value) -> i64 {
    terminal
        .get("reasoning_tokens")
        .and_then(Value::as_i64)
        .unwrap_or(0)
        .max(0)
}

pub(super) fn response_hash_bytes(p: &SettleParams) -> Vec<u8> {
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
