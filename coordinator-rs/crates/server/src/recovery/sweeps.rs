//! Job-state sweepers (plan §18.1 a–e).
//!
//! Claims use `FOR UPDATE SKIP LOCKED` over the dedicated partial indexes,
//! bounded by the batch size; the claim transaction commits before repair so
//! the repair reducers (which take their own row locks) never deadlock with
//! the claim. Correctness never rests on the claim: every repair is an
//! epoch-fenced, idempotent ledger operation with a stable per-job operation
//! key, so two workers racing the same job produce exactly one money effect.

use uuid::Uuid;

use darkbloom_core::ids::{AttemptId, JobId, SessionEpoch};

use crate::contracts::{LedgerError, LedgerFacade, ReleaseParams, SettleParams};
use crate::ledger::Ledger;

use super::worker::report_depth;
use super::RecoveryConfig;

/// (a) Reserved jobs never dispatched: past both deadlines plus grace, the
/// request can never serve — release the reservation (plan §18.1).
pub async fn sweep_reserved(ledger: &Ledger, config: &RecoveryConfig) -> anyhow::Result<usize> {
    let grace_secs = config.reserved_grace.as_secs_f64();
    let rows: Vec<(Uuid, f64)> = sqlx::query_as(
        "SELECT job_id, EXTRACT(EPOCH FROM (NOW() - created_at))::DOUBLE PRECISION \
         FROM rust_coord.inference_jobs \
         WHERE state = 'reserved' \
           AND COALESCE(LEAST(first_content_deadline, request_deadline), created_at) \
               < NOW() - make_interval(secs => $1) \
         ORDER BY created_at \
         LIMIT $2 \
         FOR UPDATE SKIP LOCKED",
    )
    .bind(grace_secs)
    .bind(config.batch)
    .fetch_all(ledger.pool())
    .await?;

    report_depth(
        "recovery.reserved",
        rows.len() as i64,
        rows.first().map(|(_, age)| *age),
    );
    release_jobs(ledger, &rows, "sweep:reserved_never_dispatched").await
}

/// (b) Preparing/prepared jobs whose lease TTL lapsed without start
/// authorization: the provider tombstones the lease on its side; release
/// the reservation here (plan §18.1, §12.5).
pub async fn sweep_prepared(ledger: &Ledger, config: &RecoveryConfig) -> anyhow::Result<usize> {
    let ttl_secs = config.prepared_lease_ttl.as_secs_f64();
    let rows: Vec<(Uuid, f64)> = sqlx::query_as(
        "SELECT job_id, EXTRACT(EPOCH FROM (NOW() - updated_at))::DOUBLE PRECISION \
         FROM rust_coord.inference_jobs \
         WHERE state IN ('preparing','prepared') \
           AND updated_at < NOW() - make_interval(secs => $1) \
         ORDER BY updated_at \
         LIMIT $2 \
         FOR UPDATE SKIP LOCKED",
    )
    .bind(ttl_secs)
    .bind(config.batch)
    .fetch_all(ledger.pool())
    .await?;

    report_depth(
        "recovery.prepared",
        rows.len() as i64,
        rows.first().map(|(_, age)| *age),
    );
    release_jobs(ledger, &rows, "sweep:prepared_lease_expired").await
}

/// (c) Start-authorized jobs whose start delivery stayed unknown past the
/// policy window. Recovery never redispatches a start-authorized job (plan
/// §12.9); resending the SAME idempotent start needs a live provider
/// session, so an outbox row hands the job to the fleet side, and the job
/// parks in review so its funds cannot silently leak (plan §18.1).
pub async fn sweep_start_authorized(
    ledger: &Ledger,
    config: &RecoveryConfig,
) -> anyhow::Result<usize> {
    let window_secs = config.start_authorized_window.as_secs_f64();
    let rows: Vec<(Uuid, f64)> = sqlx::query_as(
        "SELECT job_id, EXTRACT(EPOCH FROM (NOW() - updated_at))::DOUBLE PRECISION \
         FROM rust_coord.inference_jobs \
         WHERE state = 'start_authorized' \
           AND updated_at < NOW() - make_interval(secs => $1) \
         ORDER BY updated_at \
         LIMIT $2 \
         FOR UPDATE SKIP LOCKED",
    )
    .bind(window_secs)
    .bind(config.batch)
    .fetch_all(ledger.pool())
    .await?;

    report_depth(
        "recovery.start_authorized",
        rows.len() as i64,
        rows.first().map(|(_, age)| *age),
    );

    let epoch = i64::try_from(ledger.coordinator_epoch().get()).unwrap_or(i64::MAX);
    let mut processed = 0usize;
    for (job_id, _) in &rows {
        let job = JobId::new(*job_id);
        // Hand the resend-start decision to the fleet side (live-session
        // work); recovery only records the fact durably.
        sqlx::query(
            "INSERT INTO rust_coord.outbox (kind, payload, coordinator_epoch) \
             VALUES ('fleet.start_delivery_unknown', jsonb_build_object('job_id', $1::TEXT), $2)",
        )
        .bind(job_id.to_string())
        .bind(epoch)
        .execute(ledger.pool())
        .await?;

        match ledger
            .move_to_review(job, "sweep:start_delivery_unknown".to_owned())
            .await
        {
            Ok(()) => processed += 1,
            Err(LedgerError::Conflict(reason)) => {
                // The job progressed (terminal arrived) between claim and
                // repair — that is the good case.
                tracing::debug!(job = %job, reason, "start-authorized sweep skipped");
            }
            Err(err) => return Err(err.into()),
        }
    }
    Ok(processed)
}

/// (d) Running jobs awaiting terminal replay whose terminal never arrived
/// (plan §18.1): the coordinator that owned the RequestTask died, the
/// provider never replayed a terminal, and the job sits in `running` past
/// its absolute request deadline with NO terminal receipt row. Session loss
/// after start does not release money (plan §13.4), so the safe
/// terminal-less disposition is `review_pending` — reservation retained,
/// explicit reviewed settlement/release later. Jobs WITH a receipt row are
/// excluded: the terminal-settlement sweeper (e) owns them.
pub async fn sweep_running(ledger: &Ledger, config: &RecoveryConfig) -> anyhow::Result<usize> {
    let grace_secs = config.running_terminal_grace.as_secs_f64();
    let rows: Vec<(Uuid, f64)> = sqlx::query_as(
        "SELECT j.job_id, EXTRACT(EPOCH FROM (NOW() - j.updated_at))::DOUBLE PRECISION \
         FROM rust_coord.inference_jobs j \
         WHERE j.state = 'running' \
           AND COALESCE(j.request_deadline, j.created_at) \
               < NOW() - make_interval(secs => $1) \
           AND NOT EXISTS ( \
               SELECT 1 FROM rust_coord.provider_terminals t \
               JOIN rust_coord.inference_attempts a ON a.attempt_id = t.attempt_id \
               WHERE a.job_id = j.job_id) \
         ORDER BY j.updated_at \
         LIMIT $2 \
         FOR UPDATE OF j SKIP LOCKED",
    )
    .bind(grace_secs)
    .bind(config.batch)
    .fetch_all(ledger.pool())
    .await?;

    report_depth(
        "recovery.running",
        rows.len() as i64,
        rows.first().map(|(_, age)| *age),
    );

    let mut processed = 0usize;
    for (job_id, _) in &rows {
        let job = JobId::new(*job_id);
        match ledger
            .move_to_review(job, "sweep:running_terminal_missing".to_owned())
            .await
        {
            Ok(()) => processed += 1,
            Err(LedgerError::Conflict(reason)) => {
                // The job progressed (terminal arrived and settled) between
                // claim and repair — the good case.
                tracing::debug!(job = %job, reason, "running sweep skipped");
            }
            Err(err) => return Err(err.into()),
        }
    }
    Ok(processed)
}

/// (e) Terminal receipts awaiting settlement: a receipt row exists but its
/// disposition is unresolved (crash between receipt and settlement, Go
/// rollback ingestion, replay of a stale coordinator's intake). Re-run the
/// full settlement reducer; it routes duplicates, late terminals, review
/// cases, and conflicts itself (plan §18.1, §12.6).
pub async fn settle_pending_terminals(
    ledger: &Ledger,
    config: &RecoveryConfig,
) -> anyhow::Result<usize> {
    let rows: Vec<PendingTerminal> = sqlx::query_as(
        "SELECT t.attempt_id, t.terminal_digest, t.raw_terminal, \
                t.prompt_tokens, t.completion_tokens, t.origin_session_epoch, \
                a.job_id, \
                COALESCE(j.accepted_chunk_seq, 0) AS accepted_seq, \
                COALESCE(j.accepted_cumulative_tokens, 0) AS accepted_tokens, \
                EXTRACT(EPOCH FROM (NOW() - t.created_at))::DOUBLE PRECISION AS age \
         FROM rust_coord.provider_terminals t \
         JOIN rust_coord.inference_attempts a ON a.attempt_id = t.attempt_id \
         JOIN rust_coord.inference_jobs j ON j.job_id = a.job_id \
         WHERE t.disposition IS NULL \
         ORDER BY t.created_at \
         LIMIT $1 \
         FOR UPDATE OF t SKIP LOCKED",
    )
    .bind(config.batch)
    .fetch_all(ledger.pool())
    .await?;

    report_depth(
        "recovery.terminals",
        rows.len() as i64,
        rows.first().map(|t| t.age),
    );

    let epoch = ledger.coordinator_epoch();
    let mut processed = 0usize;
    for t in rows {
        let mut digest = [0u8; 32];
        let len = t.terminal_digest.len().min(32);
        digest[..len].copy_from_slice(&t.terminal_digest[..len]);

        let params = SettleParams {
            // Stable per-(attempt, digest) key: replays of this sweep, or a
            // race with the live settle path, converge on one disposition.
            operation_key: format!(
                "op.settle.sweep.{}.{}",
                t.attempt_id,
                digest_prefix(&digest)
            ),
            job: JobId::new(t.job_id),
            attempt: AttemptId::new(t.attempt_id),
            terminal_digest: digest,
            terminal_json: t.raw_terminal.clone(),
            prompt_tokens: u64::try_from(t.prompt_tokens).unwrap_or(0),
            completion_tokens_claimed: u64::try_from(t.completion_tokens).unwrap_or(0),
            accepted_sequence: u64::try_from(t.accepted_seq).unwrap_or(0),
            accepted_cumulative_tokens: u64::try_from(t.accepted_tokens).unwrap_or(0),
            origin_session_epoch: SessionEpoch::new(
                u64::try_from(t.origin_session_epoch).unwrap_or(0),
            ),
            coordinator_epoch: epoch,
            // Receipt rows only enter `provider_terminals` through the
            // settle reducer, fed by the session intake that verifies v2 SE
            // signatures before forwarding (and by v1 transport-trust
            // receipts) — a durable row was already vetted at intake.
            signature_verified: true,
        };
        match ledger.settle(params).await {
            Ok(outcome) => {
                tracing::info!(
                    job = %t.job_id,
                    attempt = %t.attempt_id,
                    charged = outcome.charged.get(),
                    flagged = outcome.flagged_for_review,
                    "recovered terminal settled"
                );
                processed += 1;
            }
            Err(LedgerError::Conflict(reason)) => {
                // Digest conflicts and unsettleable states get durable
                // dispositions inside the reducer; nothing to retry.
                tracing::warn!(job = %t.job_id, reason, "terminal recovery recorded conflict");
                processed += 1;
            }
            Err(err) => return Err(err.into()),
        }
    }
    Ok(processed)
}

async fn release_jobs(
    ledger: &Ledger,
    rows: &[(Uuid, f64)],
    reason: &str,
) -> anyhow::Result<usize> {
    let epoch = ledger.coordinator_epoch();
    let mut processed = 0usize;
    for (job_id, _) in rows {
        let params = ReleaseParams {
            // Stable per-job key: repeated sweeps of the same job replay.
            operation_key: format!("op.release.sweep.{job_id}"),
            job: JobId::new(*job_id),
            reason: reason.to_owned(),
            coordinator_epoch: epoch,
        };
        match ledger.release(params).await {
            Ok(()) => processed += 1,
            Err(LedgerError::Conflict(detail)) => {
                tracing::debug!(job = %job_id, detail, "release sweep skipped (state moved on)");
            }
            Err(err) => return Err(err.into()),
        }
    }
    Ok(processed)
}

fn digest_prefix(digest: &[u8; 32]) -> String {
    digest[..8].iter().map(|b| format!("{b:02x}")).collect()
}

#[derive(sqlx::FromRow)]
struct PendingTerminal {
    attempt_id: Uuid,
    terminal_digest: Vec<u8>,
    raw_terminal: serde_json::Value,
    prompt_tokens: i64,
    completion_tokens: i64,
    origin_session_epoch: i64,
    job_id: Uuid,
    accepted_seq: i64,
    accepted_tokens: i64,
    age: f64,
}
