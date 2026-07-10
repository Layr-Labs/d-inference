//! Recovery sweeper and ownership integration tests against a REAL
//! ephemeral PostgreSQL cluster (plan §18.1, §20, §22.4). Skips cleanly when
//! `initdb` is not on PATH.

#[path = "ledger_pg_support/mod.rs"]
mod support;

use std::time::Duration;

use support::flows::{self, CONSUMER, PROVIDER_BENEFICIARY, REFERRER};

use darkbloom_core::ids::JobId;
use darkbloom_server::contracts::LedgerFacade;
use darkbloom_server::ownership::OwnershipGuard;
use darkbloom_server::recovery::{
    drain_outbox, project_fees, settle_pending_terminals, sweep_prepared, sweep_reserved,
    sweep_running, sweep_start_authorized, RecoveryConfig,
};
use uuid::Uuid;

fn eager_config() -> RecoveryConfig {
    RecoveryConfig {
        interval: Duration::from_millis(10),
        jitter: Duration::ZERO,
        batch: 64,
        reserved_grace: Duration::ZERO,
        prepared_lease_ttl: Duration::ZERO,
        start_authorized_window: Duration::ZERO,
        running_terminal_grace: Duration::ZERO,
        outbox_max_attempts: 2,
    }
}

/// Ages a job's timestamps so the policy-window predicates fire.
async fn age_job(pool: &sqlx::PgPool, job: Uuid, secs: f64) {
    sqlx::query(
        "UPDATE rust_coord.inference_jobs \
         SET created_at = created_at - make_interval(secs => $2), \
             updated_at = updated_at - make_interval(secs => $2), \
             first_content_deadline = first_content_deadline - make_interval(secs => $2), \
             request_deadline = request_deadline - make_interval(secs => $2) \
         WHERE job_id = $1",
    )
    .bind(job)
    .bind(secs)
    .execute(pool)
    .await
    .expect("age job");
}

/// (a) A reserved job whose deadlines passed without any dispatch is swept
/// to `released` with its exact provenance restored (plan §18.1).
#[tokio::test]
async fn stale_reserved_job_is_swept_released() {
    if !support::pg_available() {
        support::skip();
        return;
    }
    let db = support::boot().await;
    support::set_epoch(&db.pool, 1).await;
    support::seed_consumer(&db.pool, CONSUMER, 10_000_000, 4_000_000).await;
    let ledger = support::ledger_at_epoch(&db.pool, 1);

    let job = JobId::new(Uuid::new_v4());
    ledger
        .reserve(flows::reserve_params(&ledger, job, 7_000_000, "sweep1"))
        .await
        .expect("reserve");
    assert_eq!(
        support::balance_of(&db.pool, CONSUMER).await,
        (3_000_000, 3_000_000)
    );
    age_job(&db.pool, job.get(), 400.0).await;

    let processed = sweep_reserved(&ledger, &eager_config())
        .await
        .expect("sweep");
    assert_eq!(processed, 1);
    assert_eq!(support::job_state(&db.pool, job.get()).await, "released");
    assert_eq!(
        support::balance_of(&db.pool, CONSUMER).await,
        (10_000_000, 4_000_000)
    );

    // Sweeping again is a no-op (stable operation key, terminal state).
    let processed = sweep_reserved(&ledger, &eager_config())
        .await
        .expect("re-sweep");
    assert_eq!(processed, 0);
    assert_eq!(
        support::balance_of(&db.pool, CONSUMER).await,
        (10_000_000, 4_000_000)
    );
    support::assert_ledger_consistent(&db.pool).await;

    // A FRESH reserved job (deadlines in the future) is never touched.
    let fresh = JobId::new(Uuid::new_v4());
    ledger
        .reserve(flows::reserve_params(&ledger, fresh, 1_000_000, "fresh"))
        .await
        .expect("reserve fresh");
    let processed = sweep_reserved(&ledger, &eager_config())
        .await
        .expect("sweep fresh");
    assert_eq!(processed, 0);
    assert_eq!(support::job_state(&db.pool, fresh.get()).await, "reserved");
}

/// (b) A preparing/prepared job whose lease TTL lapsed without start
/// authorization is released (plan §18.1, §12.5).
#[tokio::test]
async fn expired_prepared_job_is_swept_released() {
    if !support::pg_available() {
        support::skip();
        return;
    }
    let db = support::boot().await;
    support::set_epoch(&db.pool, 1).await;
    support::seed_consumer(&db.pool, CONSUMER, 10_000_000, 0).await;
    let ledger = support::ledger_at_epoch(&db.pool, 1);

    let job = JobId::new(Uuid::new_v4());
    ledger
        .reserve(flows::reserve_params(&ledger, job, 3_000_000, "prep"))
        .await
        .expect("reserve");
    // The request task moved the job into 'preparing' (state hop owned by
    // the live path; fixture-updated here) and then the coordinator died.
    sqlx::query(
        "UPDATE rust_coord.inference_jobs \
         SET state = 'preparing', version = version + 1 WHERE job_id = $1",
    )
    .bind(job.get())
    .execute(&db.pool)
    .await
    .expect("hop to preparing");
    age_job(&db.pool, job.get(), 120.0).await;

    let processed = sweep_prepared(&ledger, &eager_config())
        .await
        .expect("sweep");
    assert_eq!(processed, 1);
    assert_eq!(support::job_state(&db.pool, job.get()).await, "released");
    assert_eq!(
        support::balance_of(&db.pool, CONSUMER).await,
        (10_000_000, 0)
    );
}

/// (c) A start-authorized job with unknown start delivery past the policy
/// window moves to review (funds retained, never auto-released) and leaves
/// an outbox row for the fleet side (plan §18.1, §12.9).
#[tokio::test]
async fn stale_start_authorized_job_moves_to_review() {
    if !support::pg_available() {
        support::skip();
        return;
    }
    let db = support::boot().await;
    support::set_epoch(&db.pool, 1).await;
    support::seed_consumer(&db.pool, CONSUMER, 10_000_000, 4_000_000).await;
    let ledger = support::ledger_at_epoch(&db.pool, 1);

    let job = JobId::new(Uuid::new_v4());
    let attempt = darkbloom_core::ids::AttemptId::new(Uuid::new_v4());
    ledger
        .reserve(flows::reserve_params(&ledger, job, 7_000_000, "sa"))
        .await
        .expect("reserve");
    ledger
        .resize_freeze(flows::resize_params(&ledger, job, attempt, 5_000_000, "sa"))
        .await
        .expect("resize");
    let funded = support::balance_of(&db.pool, CONSUMER).await;
    age_job(&db.pool, job.get(), 300.0).await;

    let processed = sweep_start_authorized(&ledger, &eager_config())
        .await
        .expect("sweep");
    assert_eq!(processed, 1);
    assert_eq!(
        support::job_state(&db.pool, job.get()).await,
        "review_pending"
    );
    // Reservation retained (plan §12.2): review is not a release.
    assert_eq!(support::balance_of(&db.pool, CONSUMER).await, funded);
    assert_eq!(
        support::count(
            &db.pool,
            "SELECT COUNT(*) FROM rust_coord.outbox \
             WHERE kind = 'fleet.start_delivery_unknown' AND state = 'pending'"
        )
        .await,
        1
    );
}

/// (d) A running job past its request deadline with NO terminal receipt —
/// coordinator crashed mid-run, provider never replayed a terminal — is
/// parked in `review_pending` with its reservation retained (plan §18.1
/// "started jobs awaiting terminal replay"; §13.4: session loss never
/// releases money). A running job WITH a dangling receipt row is left
/// alone: the terminal-settlement sweeper owns it.
#[tokio::test]
async fn stale_running_job_without_terminal_moves_to_review() {
    if !support::pg_available() {
        support::skip();
        return;
    }
    let db = support::boot().await;
    support::set_epoch(&db.pool, 1).await;
    support::seed_consumer(&db.pool, CONSUMER, 20_000_000, 4_000_000).await;
    let ledger = support::ledger_at_epoch(&db.pool, 1);

    // A FRESH running job (deadline in the future) is never touched.
    let (job, _attempt) = flows::funded_running_job(&ledger, "run-stale").await;
    let funded = support::balance_of(&db.pool, CONSUMER).await;
    let processed = sweep_running(&ledger, &eager_config())
        .await
        .expect("sweep fresh");
    assert_eq!(processed, 0);
    assert_eq!(support::job_state(&db.pool, job.get()).await, "running");

    // Past the deadline with no receipt: parked in review, funds retained.
    age_job(&db.pool, job.get(), 400.0).await;
    let processed = sweep_running(&ledger, &eager_config())
        .await
        .expect("sweep stale");
    assert_eq!(processed, 1);
    assert_eq!(
        support::job_state(&db.pool, job.get()).await,
        "review_pending"
    );
    assert_eq!(
        support::balance_of(&db.pool, CONSUMER).await,
        funded,
        "reservation retained: review is not a release (plan §13.4)"
    );

    // Re-sweeping is a no-op (review_pending is idempotent and no longer
    // matches the running predicate).
    let processed = sweep_running(&ledger, &eager_config())
        .await
        .expect("re-sweep");
    assert_eq!(processed, 0);

    // A stale running job WITH a receipt row belongs to the settlement
    // sweeper — this sweeper must not steal it into review.
    let (with_receipt, attempt2) = flows::funded_running_job(&ledger, "run-receipt").await;
    sqlx::query(
        "INSERT INTO rust_coord.provider_terminals \
             (attempt_id, terminal_digest, raw_terminal, outcome, error_class, \
              prompt_tokens, completion_tokens, reasoning_tokens, response_hash, \
              final_generated_tokens, rolling_hash_checkpoint, provider_signature, \
              origin_session_epoch, coordinator_epoch) \
         VALUES ($1, $2, $3, 'completed', NULL, 1200, 800, 0, $4, 800, NULL, $5, 7, 1)",
    )
    .bind(attempt2.get())
    .bind(vec![0x77u8; 32])
    .bind(serde_json::json!({
        "outcome": "completed",
        "prompt_tokens": 1200,
        "completion_tokens": 800,
    }))
    .bind(vec![0xabu8; 4])
    .bind(vec![0x51u8; 4])
    .execute(&db.pool)
    .await
    .expect("insert dangling receipt");
    age_job(&db.pool, with_receipt.get(), 400.0).await;
    let processed = sweep_running(&ledger, &eager_config())
        .await
        .expect("sweep with receipt");
    assert_eq!(
        processed, 0,
        "receipt-bearing jobs go to the settle sweeper"
    );
    assert_eq!(
        support::job_state(&db.pool, with_receipt.get()).await,
        "running"
    );
}

/// (e) A terminal receipt without a settlement disposition (crash between
/// receipt intake and settlement, or replay ingestion) is settled by the
/// sweeper through the SAME reducer as the live path (plan §18.1).
#[tokio::test]
async fn terminal_receipt_without_settlement_is_settled() {
    if !support::pg_available() {
        support::skip();
        return;
    }
    let db = support::boot().await;
    support::set_epoch(&db.pool, 1).await;
    support::seed_consumer(&db.pool, CONSUMER, 10_000_000, 4_000_000).await;
    let ledger = support::ledger_at_epoch(&db.pool, 1);

    let (job, attempt) = flows::funded_running_job(&ledger, "term").await;
    // The receipt landed durably but the coordinator died before running
    // settlement: raw receipt row with NULL disposition.
    sqlx::query(
        "INSERT INTO rust_coord.provider_terminals \
             (attempt_id, terminal_digest, raw_terminal, outcome, error_class, \
              prompt_tokens, completion_tokens, reasoning_tokens, response_hash, \
              final_generated_tokens, rolling_hash_checkpoint, provider_signature, \
              origin_session_epoch, coordinator_epoch) \
         VALUES ($1, $2, $3, 'completed', NULL, 1200, 800, 0, $4, 800, NULL, $5, 7, 1)",
    )
    .bind(attempt.get())
    .bind(vec![0x99u8; 32])
    .bind(serde_json::json!({
        "outcome": "completed",
        "prompt_tokens": 1200,
        "completion_tokens": 800,
    }))
    .bind(vec![0xabu8; 4])
    .bind(vec![0x51u8; 4])
    .execute(&db.pool)
    .await
    .expect("insert dangling receipt");
    // The job recorded the coordinator's accepted checkpoint before dying.
    sqlx::query(
        "UPDATE rust_coord.inference_jobs \
         SET accepted_chunk_seq = 42, accepted_cumulative_tokens = 800 WHERE job_id = $1",
    )
    .bind(job.get())
    .execute(&db.pool)
    .await
    .expect("record checkpoint");

    let processed = settle_pending_terminals(&ledger, &eager_config())
        .await
        .expect("sweep");
    assert_eq!(processed, 1);
    assert_eq!(support::job_state(&db.pool, job.get()).await, "settled");
    assert_eq!(
        support::balance_of(&db.pool, CONSUMER).await,
        (6_000_000, 4_000_000)
    );
    assert_eq!(
        support::balance_of(&db.pool, PROVIDER_BENEFICIARY).await,
        (3_400_000, 3_400_000)
    );
    let (disposition,): (Option<String>,) = sqlx::query_as(
        "SELECT disposition FROM rust_coord.provider_terminals WHERE attempt_id = $1",
    )
    .bind(attempt.get())
    .fetch_one(&db.pool)
    .await
    .expect("receipt");
    assert_eq!(disposition.as_deref(), Some("settled"));

    // Re-running the sweeper finds nothing (disposition set).
    let processed = settle_pending_terminals(&ledger, &eager_config())
        .await
        .expect("re-sweep");
    assert_eq!(processed, 0);
}

/// (e) The single-writer fee projection folds unprojected authoritative fee
/// rows into the platform/referrer balances and legacy ledger projections;
/// the backlog reaches zero (plan §12.6, §26.1 quiescence).
#[tokio::test]
async fn unprojected_fees_are_folded_into_balances() {
    if !support::pg_available() {
        support::skip();
        return;
    }
    let db = support::boot().await;
    support::set_epoch(&db.pool, 1).await;
    support::seed_consumer(&db.pool, CONSUMER, 10_000_000, 4_000_000).await;
    let ledger = support::ledger_at_epoch(&db.pool, 1);

    let (job, attempt) = flows::funded_running_job(&ledger, "fees").await;
    ledger
        .settle(flows::settle_params(job, attempt, 0xaa, 800, 800, "fees"))
        .await
        .expect("settle");
    assert_eq!(
        support::count(
            &db.pool,
            "SELECT COUNT(*) FROM rust_coord.fee_allocations WHERE NOT projected"
        )
        .await,
        2
    );

    let processed = project_fees(&ledger, &eager_config())
        .await
        .expect("project");
    assert_eq!(processed, 2);

    // Platform fees credit total only; referral rewards are withdrawable
    // (plan §12.11).
    assert_eq!(
        support::balance_of(&db.pool, "platform").await,
        (480_000, 0)
    );
    assert_eq!(
        support::balance_of(&db.pool, REFERRER).await,
        (120_000, 120_000)
    );
    assert_eq!(
        support::count(
            &db.pool,
            "SELECT COUNT(*) FROM rust_coord.fee_allocations WHERE NOT projected"
        )
        .await,
        0
    );
    assert_eq!(
        support::count(
            &db.pool,
            "SELECT COUNT(*) FROM rust_coord.financial_operations WHERE kind = 'fee_projection'"
        )
        .await,
        2
    );
    // With fees projected, EVERY balance equals the sum of its ledger
    // entries again — full §26.3 consistency.
    support::assert_ledger_consistent(&db.pool).await;

    // Idempotent: nothing left to project.
    let processed = project_fees(&ledger, &eager_config())
        .await
        .expect("re-project");
    assert_eq!(processed, 0);
}

/// (f) The outbox drain executes pending rows (log-only executor) and
/// dead-letters rows whose executor keeps failing, within the attempt bound
/// (plan §18.1).
#[tokio::test]
async fn outbox_rows_drain_and_dead_letter() {
    if !support::pg_available() {
        support::skip();
        return;
    }
    let db = support::boot().await;
    support::set_epoch(&db.pool, 1).await;
    support::seed_consumer(&db.pool, CONSUMER, 10_000_000, 4_000_000).await;
    let ledger = support::ledger_at_epoch(&db.pool, 1);

    // A real settlement enqueues one analytics row.
    let (job, attempt) = flows::funded_running_job(&ledger, "outbox").await;
    ledger
        .settle(flows::settle_params(job, attempt, 0xbb, 800, 800, "outbox"))
        .await
        .expect("settle");
    // Plus one malformed fleet row whose executor always fails.
    sqlx::query(
        "INSERT INTO rust_coord.outbox (kind, payload, coordinator_epoch) \
         VALUES ('fleet.start_delivery_unknown', '{\"job_id\":\"not-a-uuid\"}'::jsonb, 1)",
    )
    .execute(&db.pool)
    .await
    .expect("insert poison row");

    let mut config = eager_config();
    config.outbox_max_attempts = 2;

    // First pass: analytics done; poison row retried (attempts 1, backoff).
    drain_outbox(&ledger, &config).await.expect("drain 1");
    assert_eq!(
        support::count(
            &db.pool,
            "SELECT COUNT(*) FROM rust_coord.outbox WHERE state = 'done'"
        )
        .await,
        1
    );
    // Make the poison row due again immediately, then dead-letter it.
    sqlx::query("UPDATE rust_coord.outbox SET next_attempt_at = NOW() WHERE state = 'pending'")
        .execute(&db.pool)
        .await
        .expect("expire backoff");
    drain_outbox(&ledger, &config).await.expect("drain 2");
    assert_eq!(
        support::count(
            &db.pool,
            "SELECT COUNT(*) FROM rust_coord.outbox WHERE state = 'dead'"
        )
        .await,
        1
    );
    assert_eq!(
        support::count(
            &db.pool,
            "SELECT COUNT(*) FROM rust_coord.outbox WHERE state = 'pending'"
        )
        .await,
        0
    );
}

/// Ownership guard (plan §20): the advisory lock + fencing epoch increment,
/// health watch, and graceful release as the final mutating action.
#[tokio::test]
async fn ownership_guard_takes_lock_and_increments_epoch() {
    if !support::pg_available() {
        support::skip();
        return;
    }
    let db = support::boot().await;

    let guard = OwnershipGuard::acquire(&db.url, "test-holder-1")
        .await
        .expect("acquire ownership");
    assert_eq!(guard.epoch().get(), 1);
    assert!(guard.is_healthy());

    let (holder,): (String,) =
        sqlx::query_as("SELECT holder FROM rust_coord.coordinator_ownership WHERE id = 1")
            .fetch_one(&db.pool)
            .await
            .expect("read holder");
    assert_eq!(holder, "test-holder-1");

    // A second acquire BLOCKS on the advisory lock until release: prove it
    // completes only after the first guard releases.
    let url = db.url.clone();
    let second = tokio::spawn(async move {
        OwnershipGuard::acquire(&url, "test-holder-2")
            .await
            .expect("second acquire")
    });
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(
        !second.is_finished(),
        "second acquire must block on the advisory lock"
    );

    let mut health = guard.health_watch();
    guard.release().await.expect("release");
    assert!(
        !*health.borrow_and_update(),
        "health watch flips on release"
    );

    let second = tokio::time::timeout(Duration::from_secs(10), second)
        .await
        .expect("second acquire must unblock after release")
        .expect("join");
    assert_eq!(second.epoch().get(), 2, "epoch increments per acquisition");
    second.release().await.expect("release second");
}

/// Plan §20 regression for the keeper's ping TIMEOUT: a half-open (black-
/// holed) lock connection produces neither data nor an error. `SIGSTOP` on
/// the keeper's dedicated backend reproduces exactly that — the ping is
/// written, nothing ever answers — so ONLY the bounded ping can flip the
/// health watch. Without the timeout this test hangs at "healthy" forever.
#[tokio::test]
async fn ownership_ping_timeout_detects_blackholed_connection() {
    if !support::pg_available() {
        support::skip();
        return;
    }
    let db = support::boot().await;

    let guard = OwnershipGuard::acquire(&db.url, "blackhole-test")
        .await
        .expect("acquire ownership");
    assert!(guard.is_healthy());
    let mut health = guard.health_watch();

    // The only advisory lock in this throwaway cluster is the keeper's.
    let pids: Vec<(i32,)> = sqlx::query_as("SELECT pid FROM pg_locks WHERE locktype = 'advisory'")
        .fetch_all(&db.pool)
        .await
        .expect("find lock backend");
    assert!(!pids.is_empty(), "the keeper's backend must exist");

    /// Resumes the stopped backends even when the test panics, so the
    /// cluster teardown (`pg_ctl stop -m immediate`) can complete.
    struct ResumeOnDrop(Vec<i32>);
    impl Drop for ResumeOnDrop {
        fn drop(&mut self) {
            for pid in &self.0 {
                let _ = std::process::Command::new("kill")
                    .args(["-CONT", &pid.to_string()])
                    .status();
            }
        }
    }
    let _resume = ResumeOnDrop(pids.iter().map(|(pid,)| *pid).collect());
    for (pid,) in &pids {
        let status = std::process::Command::new("kill")
            .args(["-STOP", &pid.to_string()])
            .status()
            .expect("send SIGSTOP");
        assert!(status.success(), "SIGSTOP backend {pid}");
    }

    // Worst case: up to one full interval (5s) until the next ping plus the
    // ping bound (5s). Only the timeout can fire — the socket stays open.
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            if !*health.borrow_and_update() {
                return;
            }
            if health.changed().await.is_err() {
                return;
            }
        }
    })
    .await
    .expect("health must flip via the ping timeout on a black-holed connection");
    assert!(!guard.is_healthy());
}

/// Plan §20: killing the dedicated lock connection server-side must flip
/// the health watch within the keeper's ping window, and the guard must
/// NEVER auto-reacquire — health stays false permanently (a reacquire would
/// be a NEW epoch; the plan's answer to ownership loss is process restart).
#[tokio::test]
async fn ownership_health_flips_when_lock_connection_killed() {
    if !support::pg_available() {
        support::skip();
        return;
    }
    let db = support::boot().await;

    let guard = OwnershipGuard::acquire(&db.url, "kill-test")
        .await
        .expect("acquire ownership");
    assert!(guard.is_healthy());
    let first_epoch = guard.epoch().get();
    let mut health = guard.health_watch();

    // Terminate the advisory-lock holder from the pool: the ONLY advisory
    // lock in this throwaway cluster is the keeper's.
    let killed: Vec<(bool,)> = sqlx::query_as(
        "SELECT pg_terminate_backend(pid) FROM pg_locks WHERE locktype = 'advisory'",
    )
    .fetch_all(&db.pool)
    .await
    .expect("terminate lock backend");
    assert!(!killed.is_empty(), "the keeper's backend must exist");

    // The next keeper ping (interval 5s, ping bound 5s) must flip health.
    tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            if !*health.borrow_and_update() {
                return;
            }
            if health.changed().await.is_err() {
                return;
            }
        }
    })
    .await
    .expect("health must flip within the ping window");
    assert!(!guard.is_healthy());

    // No auto-reacquire: the lock died with the backend, so a successor
    // acquires immediately with the NEXT epoch — while the old guard stays
    // permanently unhealthy.
    let successor = OwnershipGuard::acquire(&db.url, "successor")
        .await
        .expect("successor acquires the freed lock");
    assert_eq!(successor.epoch().get(), first_epoch + 1);
    assert!(
        !guard.is_healthy(),
        "a guard that lost its connection must never report healthy again"
    );
    successor.release().await.expect("release successor");
}
