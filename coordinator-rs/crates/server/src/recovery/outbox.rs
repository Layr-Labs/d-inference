//! The outbox drain (plan §18.1 f, §12.1).
//!
//! `rust_coord.outbox` rows are non-critical side effects (analytics,
//! fleet notifications); they never carry money authority. The executor is
//! log-only for now — the integration phase plugs real emitters in per
//! `kind`. Failed executions retry with exponential backoff up to the
//! configured attempt bound, then dead-letter (`state = 'dead'`) for
//! operator review.

use serde_json::Value;
use uuid::Uuid;

use crate::ledger::Ledger;

use super::worker::report_depth;
use super::RecoveryConfig;

/// One drain tick. Returns the number of rows executed (done or dead).
pub async fn drain_outbox(ledger: &Ledger, config: &RecoveryConfig) -> anyhow::Result<usize> {
    let (depth, oldest): (i64, Option<f64>) = sqlx::query_as(
        "SELECT COUNT(*), \
                MAX(EXTRACT(EPOCH FROM (NOW() - created_at)))::DOUBLE PRECISION \
         FROM rust_coord.outbox WHERE state = 'pending'",
    )
    .fetch_one(ledger.pool())
    .await?;
    report_depth("recovery.outbox", depth, oldest);
    if depth == 0 {
        return Ok(0);
    }

    // Claim due rows. The row lock is the worker lease; it expires with this
    // transaction, so a crashed drain never wedges a row.
    let mut tx = ledger.pool().begin().await?;
    let rows: Vec<(i64, String, Value, i32)> = sqlx::query_as(
        "SELECT id, kind, payload, attempts FROM rust_coord.outbox \
         WHERE state = 'pending' AND next_attempt_at <= NOW() \
         ORDER BY next_attempt_at \
         LIMIT $1 \
         FOR UPDATE SKIP LOCKED",
    )
    .bind(config.batch)
    .fetch_all(&mut *tx)
    .await?;

    let mut processed = 0usize;
    for (id, kind, payload, attempts) in rows {
        match execute(&kind, &payload) {
            Ok(()) => {
                sqlx::query(
                    "UPDATE rust_coord.outbox \
                     SET state = 'done', attempts = attempts + 1 \
                     WHERE id = $1",
                )
                .bind(id)
                .execute(&mut *tx)
                .await?;
                processed += 1;
            }
            Err(reason) => {
                let next_attempts = attempts + 1;
                if next_attempts >= config.outbox_max_attempts {
                    tracing::warn!(id, kind, reason, "outbox row dead-lettered");
                    sqlx::query(
                        "UPDATE rust_coord.outbox \
                         SET state = 'dead', attempts = $2 \
                         WHERE id = $1",
                    )
                    .bind(id)
                    .bind(next_attempts)
                    .execute(&mut *tx)
                    .await?;
                    processed += 1;
                } else {
                    // Exponential backoff, capped at ~17 minutes.
                    let backoff_secs = 2i64.saturating_pow(next_attempts.min(10) as u32);
                    sqlx::query(
                        "UPDATE rust_coord.outbox \
                         SET attempts = $2, \
                             next_attempt_at = NOW() + make_interval(secs => $3) \
                         WHERE id = $1",
                    )
                    .bind(id)
                    .bind(next_attempts)
                    .bind(backoff_secs as f64)
                    .execute(&mut *tx)
                    .await?;
                }
            }
        }
    }
    tx.commit().await?;
    Ok(processed)
}

/// Log-only executor (plan §18.1: outbox retries carry no money authority).
/// Payloads are IDs and amounts only — never prompt or response content.
fn execute(kind: &str, payload: &Value) -> Result<(), String> {
    match kind {
        "settlement.analytics" => {
            let job_id = payload
                .get("job_id")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned();
            let charged = payload
                .get("charged_micro_usd")
                .and_then(Value::as_i64)
                .unwrap_or(0);
            tracing::info!(kind, job_id, charged, "outbox: settlement analytics");
            Ok(())
        }
        "fleet.start_delivery_unknown" => {
            let job = payload.get("job_id").and_then(Value::as_str).unwrap_or("");
            // Validate the payload shape so the fleet consumer can trust it.
            if Uuid::parse_str(job).is_err() {
                return Err(format!("malformed job_id in payload: {payload}"));
            }
            tracing::warn!(
                kind,
                job_id = job,
                "outbox: start delivery unknown — fleet must resend the same idempotent start \
                 or confirm no-start (plan §18.1)"
            );
            Ok(())
        }
        other => {
            tracing::info!(kind = other, "outbox: unrecognized kind (logged, done)");
            Ok(())
        }
    }
}
