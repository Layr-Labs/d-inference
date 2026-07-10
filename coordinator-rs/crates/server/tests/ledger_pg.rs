//! Ledger integration tests against a REAL ephemeral PostgreSQL cluster
//! (plan §22.4): reserve/resize/settle/release idempotency, provenance,
//! spend caps, terminal replay and conflict, review parking, and the
//! coordinator epoch fence. Skips cleanly when `initdb` is not on PATH.

#[path = "ledger_pg_support/mod.rs"]
mod support;

use support::flows::{self, CONSUMER, PROVIDER_BENEFICIARY, REFERRER};

use darkbloom_core::ids::{AttemptId, JobId};
use darkbloom_core::money::MicroUsd;
use darkbloom_server::contracts::{ApiKeyStore, LedgerError, LedgerFacade};
use uuid::Uuid;

/// Reserve debits once with exact provenance; replaying the SAME operation
/// key (the ambiguous-commit / kill-at-boundary recovery path, plan §12.5)
/// returns the stored outcome and moves nothing.
#[tokio::test]
async fn reserve_idempotent_replay_debits_once() {
    if !support::pg_available() {
        support::skip();
        return;
    }
    let db = support::boot().await;
    support::set_epoch(&db.pool, 1).await;
    support::seed_consumer(&db.pool, CONSUMER, 10_000_000, 4_000_000).await;
    let ledger = support::ledger_at_epoch(&db.pool, 1);

    let job = JobId::new(Uuid::new_v4());
    let params = flows::reserve_params(&ledger, job, 7_000_000, "job1");
    let first = ledger.reserve(params.clone()).await.expect("reserve");
    assert_eq!(first.reserved_total.get(), 7_000_000);
    // nonwithdrawable = 10M - 4M = 6M; withdrawable component = 7M - 6M = 1M.
    assert_eq!(first.reserved_withdrawable.get(), 1_000_000);
    assert_eq!(
        support::balance_of(&db.pool, CONSUMER).await,
        (3_000_000, 3_000_000)
    );

    // Identical replay: single debit, identical stored outcome.
    let replay = ledger.reserve(params).await.expect("reserve replay");
    assert_eq!(replay.reserved_total.get(), 7_000_000);
    assert_eq!(replay.reserved_withdrawable.get(), 1_000_000);
    assert_eq!(
        support::balance_of(&db.pool, CONSUMER).await,
        (3_000_000, 3_000_000)
    );
    assert_eq!(
        support::count(&db.pool, "SELECT COUNT(*) FROM rust_coord.inference_jobs").await,
        1
    );
    assert_eq!(
        support::count(
            &db.pool,
            "SELECT COUNT(*) FROM ledger_entries WHERE entry_type = 'charge'"
        )
        .await,
        1
    );
    support::assert_ledger_consistent(&db.pool).await;
}

#[tokio::test]
async fn reserve_insufficient_funds_moves_nothing() {
    if !support::pg_available() {
        support::skip();
        return;
    }
    let db = support::boot().await;
    support::set_epoch(&db.pool, 1).await;
    support::seed_consumer(&db.pool, CONSUMER, 1_000_000, 0).await;
    let ledger = support::ledger_at_epoch(&db.pool, 1);

    let job = JobId::new(Uuid::new_v4());
    let err = ledger
        .reserve(flows::reserve_params(&ledger, job, 2_000_000, "poor"))
        .await
        .expect_err("must fail");
    assert!(matches!(err, LedgerError::InsufficientFunds), "got {err:?}");
    assert_eq!(
        support::balance_of(&db.pool, CONSUMER).await,
        (1_000_000, 0)
    );
    assert_eq!(
        support::count(&db.pool, "SELECT COUNT(*) FROM rust_coord.inference_jobs").await,
        0
    );
    assert_eq!(
        support::count(
            &db.pool,
            "SELECT COUNT(*) FROM rust_coord.financial_operations"
        )
        .await,
        0
    );
}

/// The per-key spend cap is enforced against settled spend plus ACTIVE Rust
/// reservations in the same atomic statement (plan §12.5).
#[tokio::test]
async fn reserve_enforces_spend_cap_against_active_reservations() {
    if !support::pg_available() {
        support::skip();
        return;
    }
    let db = support::boot().await;
    support::set_epoch(&db.pool, 1).await;
    support::seed_consumer(&db.pool, CONSUMER, 20_000_000, 0).await;
    let ledger = support::ledger_at_epoch(&db.pool, 1);

    let mut first = flows::reserve_params(&ledger, JobId::new(Uuid::new_v4()), 3_000_000, "cap1");
    first.spend_cap = Some(MicroUsd::new(5_000_000));
    ledger
        .reserve(first)
        .await
        .expect("first reserve under cap");

    // 3M active + 3M requested > 5M cap.
    let mut second = flows::reserve_params(&ledger, JobId::new(Uuid::new_v4()), 3_000_000, "cap2");
    second.spend_cap = Some(MicroUsd::new(5_000_000));
    let err = ledger.reserve(second).await.expect_err("must exceed cap");
    assert!(matches!(err, LedgerError::SpendCapExceeded), "got {err:?}");

    // Settled spend counts too: historical usage on the key eats the cap.
    sqlx::query(
        "INSERT INTO usage (provider_id, consumer_key_hash, key_id, model, \
         prompt_tokens, completion_tokens, cost_micro_usd) \
         VALUES ('prov', '', 'key_test1', 'm', 1, 1, 4000000)",
    )
    .execute(&db.pool)
    .await
    .expect("insert usage");
    let mut third = flows::reserve_params(&ledger, JobId::new(Uuid::new_v4()), 1_000_000, "cap3");
    third.spend_cap = Some(MicroUsd::new(8_000_000));
    // 4M settled + 3M active + 1M requested = 8M <= 8M cap: allowed.
    ledger.reserve(third).await.expect("exactly at cap");
}

/// Resize adjusts the reservation to the exact prepared hold (refunding the
/// provenance difference), freezes every term column, authorizes start, and
/// replays idempotently (plan §12.4, §12.5; smoke resize shape).
#[tokio::test]
async fn resize_freeze_adjusts_reservation_and_freezes_terms() {
    if !support::pg_available() {
        support::skip();
        return;
    }
    let db = support::boot().await;
    support::set_epoch(&db.pool, 1).await;
    support::seed_consumer(&db.pool, CONSUMER, 10_000_000, 4_000_000).await;
    let ledger = support::ledger_at_epoch(&db.pool, 1);

    let job = JobId::new(Uuid::new_v4());
    let attempt = AttemptId::new(Uuid::new_v4());
    ledger
        .reserve(flows::reserve_params(&ledger, job, 7_000_000, "rz"))
        .await
        .expect("reserve");
    let params = flows::resize_params(&ledger, job, attempt, 5_000_000, "rz");
    ledger.resize_freeze(params.clone()).await.expect("resize");

    // Restored 10M/4M, re-reserved 5M with withdrawable component
    // max(0, 5M - 6M) = 0: balance 5M, withdrawable back to 4M.
    assert_eq!(
        support::balance_of(&db.pool, CONSUMER).await,
        (5_000_000, 4_000_000)
    );
    assert_eq!(
        support::job_state(&db.pool, job.get()).await,
        "start_authorized"
    );

    let (total, wd, model, beneficiary): (i64, i64, Option<String>, Option<String>) =
        sqlx::query_as(
            "SELECT reserved_total_micro_usd, reserved_withdrawable_micro_usd, \
                    concrete_model, beneficiary_account_id \
             FROM rust_coord.inference_jobs WHERE job_id = $1",
        )
        .bind(job.get())
        .fetch_one(&db.pool)
        .await
        .expect("job row");
    assert_eq!((total, wd), (5_000_000, 0));
    assert_eq!(model.as_deref(), Some("qwen3-30b-a3b-4bit"));
    assert_eq!(beneficiary.as_deref(), Some(PROVIDER_BENEFICIARY));

    // Attempt bound to its prepared lease.
    let (attempt_state,): (String,) =
        sqlx::query_as("SELECT state FROM rust_coord.inference_attempts WHERE attempt_id = $1")
            .bind(attempt.get())
            .fetch_one(&db.pool)
            .await
            .expect("attempt row");
    assert_eq!(attempt_state, "prepared");

    // Idempotent replay.
    ledger.resize_freeze(params).await.expect("resize replay");
    assert_eq!(
        support::balance_of(&db.pool, CONSUMER).await,
        (5_000_000, 4_000_000)
    );
    support::assert_ledger_consistent(&db.pool).await;
}

/// Full happy path (plan §12.6): charge 4M at 800 accepted completion
/// tokens, refund 1M, payout 3.4M, authoritative fee rows for platform
/// (480k) and referrer (120k), every legacy projection exactly once, and a
/// duplicate settle (same operation key) that no-ops.
#[tokio::test]
async fn settle_happy_path_with_fees_and_projections() {
    if !support::pg_available() {
        support::skip();
        return;
    }
    let db = support::boot().await;
    support::set_epoch(&db.pool, 1).await;
    support::seed_consumer(&db.pool, CONSUMER, 10_000_000, 4_000_000).await;
    let ledger = support::ledger_at_epoch(&db.pool, 1);

    let (job, attempt) = flows::funded_running_job(&ledger, "hp").await;
    let params = flows::settle_params(job, attempt, 0x11, 800, 800, "hp");
    let outcome = ledger.settle(params.clone()).await.expect("settle");

    assert_eq!(outcome.charged.get(), 4_000_000);
    assert_eq!(outcome.refunded.get(), 1_000_000);
    assert_eq!(outcome.provider_payout.get(), 3_400_000);
    assert!(!outcome.flagged_for_review);

    assert_eq!(
        support::balance_of(&db.pool, CONSUMER).await,
        (6_000_000, 4_000_000)
    );
    assert_eq!(
        support::balance_of(&db.pool, PROVIDER_BENEFICIARY).await,
        (3_400_000, 3_400_000)
    );
    // Platform/referrer balances are NOT updated synchronously (plan §12.6).
    assert_eq!(support::balance_of(&db.pool, "platform").await, (0, 0));
    assert_eq!(support::balance_of(&db.pool, REFERRER).await, (0, 0));

    // Authoritative fee rows: payout + fees == collected charge (§9.3.5).
    let fees: Vec<(String, String, i64)> = sqlx::query_as(
        "SELECT beneficiary_account_id, kind, amount_micro_usd \
         FROM rust_coord.fee_allocations WHERE job_id = $1 ORDER BY kind",
    )
    .bind(job.get())
    .fetch_all(&db.pool)
    .await
    .expect("fees");
    assert_eq!(
        fees,
        vec![
            ("platform".to_owned(), "platform".to_owned(), 480_000),
            (REFERRER.to_owned(), "referral".to_owned(), 120_000),
        ]
    );
    assert_eq!(3_400_000 + 480_000 + 120_000, 4_000_000);

    // Legacy projections exactly once.
    assert_eq!(
        support::count(&db.pool, "SELECT COUNT(*) FROM usage").await,
        1
    );
    assert_eq!(
        support::count(&db.pool, "SELECT COUNT(*) FROM provider_earnings").await,
        1
    );
    assert_eq!(
        support::count(
            &db.pool,
            "SELECT total_requests FROM usage_totals WHERE id = 1"
        )
        .await,
        1
    );
    assert_eq!(
        support::count(
            &db.pool,
            "SELECT total_micro_usd FROM earnings_summary \
             WHERE key = 'acct_provider' AND key_type = 'account'"
        )
        .await,
        3_400_000
    );
    assert_eq!(support::job_state(&db.pool, job.get()).await, "settled");

    // §26.3: consumer-side operation flow nets to exactly -charge.
    let (net_total, net_wd): (i64, i64) = sqlx::query_as(
        "SELECT COALESCE(SUM(amount_total_micro_usd), 0)::BIGINT, \
                COALESCE(SUM(amount_withdrawable_micro_usd), 0)::BIGINT \
         FROM rust_coord.financial_operations \
         WHERE job_id = $1 AND kind IN ('reserve','resize','settle')",
    )
    .bind(job.get())
    .fetch_one(&db.pool)
    .await
    .expect("op sums");
    assert_eq!((net_total, net_wd), (-4_000_000, 0));
    support::assert_ledger_consistent(&db.pool).await;

    // Duplicate settle, same operation key: byte-identical outcome, no
    // second credit anywhere.
    let replay = ledger.settle(params).await.expect("settle replay");
    assert_eq!(replay.charged.get(), 4_000_000);
    assert_eq!(replay.provider_payout.get(), 3_400_000);
    assert_eq!(
        support::balance_of(&db.pool, PROVIDER_BENEFICIARY).await,
        (3_400_000, 3_400_000)
    );
    assert_eq!(
        support::count(&db.pool, "SELECT COUNT(*) FROM provider_earnings").await,
        1
    );
}

/// The same terminal digest replayed through a DIFFERENT operation key (a
/// provider reconnect replay) returns the stored disposition and bumps
/// `received_count` — no money (plan §12.8).
#[tokio::test]
async fn same_digest_terminal_replay_returns_disposition() {
    if !support::pg_available() {
        support::skip();
        return;
    }
    let db = support::boot().await;
    support::set_epoch(&db.pool, 1).await;
    support::seed_consumer(&db.pool, CONSUMER, 10_000_000, 4_000_000).await;
    let ledger = support::ledger_at_epoch(&db.pool, 1);

    let (job, attempt) = flows::funded_running_job(&ledger, "replay").await;
    ledger
        .settle(flows::settle_params(job, attempt, 0x22, 800, 800, "replay"))
        .await
        .expect("settle");

    let replayed = ledger
        .settle(flows::settle_params(
            job,
            attempt,
            0x22,
            800,
            800,
            "replay-again",
        ))
        .await
        .expect("digest replay");
    assert_eq!(replayed.charged.get(), 4_000_000);
    assert_eq!(replayed.provider_payout.get(), 3_400_000);

    let (received, disposition): (i32, Option<String>) = sqlx::query_as(
        "SELECT received_count, disposition FROM rust_coord.provider_terminals \
         WHERE attempt_id = $1",
    )
    .bind(attempt.get())
    .fetch_one(&db.pool)
    .await
    .expect("receipt");
    assert_eq!(received, 2);
    assert_eq!(disposition.as_deref(), Some("settled"));
    assert_eq!(
        support::balance_of(&db.pool, PROVIDER_BENEFICIARY).await,
        (3_400_000, 3_400_000)
    );
}

/// The same attempt with a DIFFERENT digest is a protocol conflict: every
/// receipt row is flagged, the error is typed, and no money moves
/// (plan §12.8, §18 "Terminal conflict").
#[tokio::test]
async fn different_digest_conflict_moves_no_money() {
    if !support::pg_available() {
        support::skip();
        return;
    }
    let db = support::boot().await;
    support::set_epoch(&db.pool, 1).await;
    support::seed_consumer(&db.pool, CONSUMER, 10_000_000, 4_000_000).await;
    let ledger = support::ledger_at_epoch(&db.pool, 1);

    let (job, attempt) = flows::funded_running_job(&ledger, "conflict").await;
    ledger
        .settle(flows::settle_params(
            job, attempt, 0x33, 800, 800, "conflict",
        ))
        .await
        .expect("settle");
    let before_consumer = support::balance_of(&db.pool, CONSUMER).await;
    let before_provider = support::balance_of(&db.pool, PROVIDER_BENEFICIARY).await;

    // Same attempt, different digest, claiming MORE tokens.
    let err = ledger
        .settle(flows::settle_params(
            job,
            attempt,
            0x44,
            1500,
            1500,
            "conflict2",
        ))
        .await
        .expect_err("must conflict");
    assert!(matches!(err, LedgerError::Conflict(_)), "got {err:?}");

    assert_eq!(
        support::balance_of(&db.pool, CONSUMER).await,
        before_consumer
    );
    assert_eq!(
        support::balance_of(&db.pool, PROVIDER_BENEFICIARY).await,
        before_provider
    );
    assert_eq!(
        support::count(
            &db.pool,
            "SELECT COUNT(*) FROM rust_coord.provider_terminals WHERE conflict"
        )
        .await,
        2
    );
    // The settled job stays settled; the conflict is quarantined at the
    // receipt level.
    assert_eq!(support::job_state(&db.pool, job.get()).await, "settled");
}

/// Release restores the EXACT total and withdrawable provenance recorded in
/// the job row and replays idempotently (plan §12.7).
#[tokio::test]
async fn release_restores_exact_provenance() {
    if !support::pg_available() {
        support::skip();
        return;
    }
    let db = support::boot().await;
    support::set_epoch(&db.pool, 1).await;
    support::seed_consumer(&db.pool, CONSUMER, 6_000_000, 4_000_000).await;
    let ledger = support::ledger_at_epoch(&db.pool, 1);

    // nonwithdrawable = 2M; withdrawable component = 4M - 2M = 2M.
    let job = JobId::new(Uuid::new_v4());
    ledger
        .reserve(flows::reserve_params(&ledger, job, 4_000_000, "rel"))
        .await
        .expect("reserve");
    assert_eq!(
        support::balance_of(&db.pool, CONSUMER).await,
        (2_000_000, 2_000_000)
    );

    let params = darkbloom_server::contracts::ReleaseParams {
        operation_key: "op.release.rel".to_owned(),
        job,
        reason: "test:client_gone".to_owned(),
        coordinator_epoch: darkbloom_core::ids::CoordinatorEpoch::new(1),
    };
    ledger.release(params.clone()).await.expect("release");
    assert_eq!(
        support::balance_of(&db.pool, CONSUMER).await,
        (6_000_000, 4_000_000)
    );
    assert_eq!(support::job_state(&db.pool, job.get()).await, "released");

    // Replay and a different-key release both no-op.
    ledger.release(params).await.expect("release replay");
    let mut other = darkbloom_server::contracts::ReleaseParams {
        operation_key: "op.release.rel2".to_owned(),
        job,
        reason: "test:sweeper".to_owned(),
        coordinator_epoch: darkbloom_core::ids::CoordinatorEpoch::new(1),
    };
    ledger
        .release(other.clone())
        .await
        .expect("idempotent across keys");
    other.operation_key = "op.release.rel3".to_owned();
    ledger.release(other).await.expect("still idempotent");
    assert_eq!(
        support::balance_of(&db.pool, CONSUMER).await,
        (6_000_000, 4_000_000)
    );

    // §26.3: a released job nets to zero in both components.
    let (net_total, net_wd): (i64, i64) = sqlx::query_as(
        "SELECT COALESCE(SUM(amount_total_micro_usd), 0)::BIGINT, \
                COALESCE(SUM(amount_withdrawable_micro_usd), 0)::BIGINT \
         FROM rust_coord.financial_operations WHERE job_id = $1",
    )
    .bind(job.get())
    .fetch_one(&db.pool)
    .await
    .expect("sums");
    assert_eq!((net_total, net_wd), (0, 0));
    support::assert_ledger_consistent(&db.pool).await;
}

/// A terminal arriving AFTER release is recorded and acknowledged as late
/// but moves no money (plan §12.7).
#[tokio::test]
async fn terminal_after_release_is_recorded_late() {
    if !support::pg_available() {
        support::skip();
        return;
    }
    let db = support::boot().await;
    support::set_epoch(&db.pool, 1).await;
    support::seed_consumer(&db.pool, CONSUMER, 6_000_000, 0).await;
    let ledger = support::ledger_at_epoch(&db.pool, 1);

    let job = JobId::new(Uuid::new_v4());
    let attempt = AttemptId::new(Uuid::new_v4());
    ledger
        .reserve(flows::reserve_params(&ledger, job, 4_000_000, "late"))
        .await
        .expect("reserve");
    // Attempt was dispatched (fixture: the request task records it) but the
    // job released before any terminal arrived.
    sqlx::query(
        "INSERT INTO rust_coord.inference_attempts \
             (attempt_id, job_id, provider_stable_id, session_epoch, coordinator_epoch, \
              dispatch_nonce, request_digest, state) \
         VALUES ($1, $2, 'prov_1', 7, 1, $3, $4, 'aborted')",
    )
    .bind(attempt.get())
    .bind(job.get())
    .bind(vec![1u8])
    .bind(vec![2u8])
    .execute(&db.pool)
    .await
    .expect("insert attempt fixture");
    ledger
        .release(darkbloom_server::contracts::ReleaseParams {
            operation_key: "op.release.late".to_owned(),
            job,
            reason: "test:pre_terminal".to_owned(),
            coordinator_epoch: darkbloom_core::ids::CoordinatorEpoch::new(1),
        })
        .await
        .expect("release");
    let restored = support::balance_of(&db.pool, CONSUMER).await;

    let late = ledger
        .settle(flows::settle_params(job, attempt, 0x55, 100, 100, "late"))
        .await
        .expect("late terminal");
    assert_eq!(late.charged.get(), 0);
    assert_eq!(late.provider_payout.get(), 0);
    assert!(!late.flagged_for_review);
    assert_eq!(support::balance_of(&db.pool, CONSUMER).await, restored);

    let (disposition,): (Option<String>,) = sqlx::query_as(
        "SELECT disposition FROM rust_coord.provider_terminals WHERE attempt_id = $1",
    )
    .bind(attempt.get())
    .fetch_one(&db.pool)
    .await
    .expect("receipt");
    assert_eq!(disposition.as_deref(), Some("late"));
    assert_eq!(support::job_state(&db.pool, job.get()).await, "released");
}

/// Completion above the funded bound (or the accepted checkpoint) caps and
/// parks the job in review WITHOUT moving money: `review_pending` retains
/// its reservation (plan §9.3.8, §12.2).
#[tokio::test]
async fn capped_completion_flags_review_and_retains_reservation() {
    if !support::pg_available() {
        support::skip();
        return;
    }
    let db = support::boot().await;
    support::set_epoch(&db.pool, 1).await;
    support::seed_consumer(&db.pool, CONSUMER, 10_000_000, 4_000_000).await;
    let ledger = support::ledger_at_epoch(&db.pool, 1);

    let (job, attempt) = flows::funded_running_job(&ledger, "review").await;
    let after_resize = support::balance_of(&db.pool, CONSUMER).await;

    // Claims 3000 completion tokens against a 1000-token funded bound.
    let outcome = ledger
        .settle(flows::settle_params(
            job, attempt, 0x66, 3000, 3000, "review",
        ))
        .await
        .expect("settle routes to review");
    assert!(outcome.flagged_for_review);
    assert_eq!(outcome.charged.get(), 0);
    assert_eq!(outcome.provider_payout.get(), 0);

    assert_eq!(
        support::job_state(&db.pool, job.get()).await,
        "review_pending"
    );
    // Reservation retained: balances unchanged from the post-resize state.
    assert_eq!(support::balance_of(&db.pool, CONSUMER).await, after_resize);
    assert_eq!(
        support::balance_of(&db.pool, PROVIDER_BENEFICIARY).await,
        (0, 0)
    );
    assert_eq!(
        support::count(&db.pool, "SELECT COUNT(*) FROM rust_coord.fee_allocations").await,
        0
    );
}

/// Defense-in-depth on plan §12.6 step 3: a v2 terminal whose SE signature
/// was NOT verified at intake parks the job in review — money never moves
/// on an unverified claim. A v1 receipt (`"protocol":"v1"`) still settles
/// with `signature_verified = false`: v1 has no signed terminal and settles
/// on transport trust (Go parity).
#[tokio::test]
async fn unverified_v2_terminal_parks_review_but_v1_settles() {
    if !support::pg_available() {
        support::skip();
        return;
    }
    let db = support::boot().await;
    support::set_epoch(&db.pool, 1).await;
    support::seed_consumer(&db.pool, CONSUMER, 20_000_000, 4_000_000).await;
    let ledger = support::ledger_at_epoch(&db.pool, 1);

    // (1) Unverified v2-shaped terminal: review, no money.
    let (job, attempt) = flows::funded_running_job(&ledger, "unverified").await;
    let after_resize = support::balance_of(&db.pool, CONSUMER).await;
    let mut params = flows::settle_params(job, attempt, 0x77, 800, 800, "unverified");
    params.signature_verified = false;
    let outcome = ledger
        .settle(params)
        .await
        .expect("settle routes to review");
    assert!(outcome.flagged_for_review);
    assert_eq!(outcome.charged.get(), 0);
    assert_eq!(
        support::job_state(&db.pool, job.get()).await,
        "review_pending"
    );
    assert_eq!(support::balance_of(&db.pool, CONSUMER).await, after_resize);
    assert_eq!(
        support::balance_of(&db.pool, PROVIDER_BENEFICIARY).await,
        (0, 0)
    );
    let (error_class,): (Option<String>,) =
        sqlx::query_as("SELECT error_class FROM rust_coord.inference_jobs WHERE job_id = $1")
            .bind(job.get())
            .fetch_one(&db.pool)
            .await
            .expect("job row");
    assert_eq!(
        error_class.as_deref(),
        Some("terminal_signature_unverified")
    );

    // (2) v1 receipt with signature_verified = false: settles normally.
    let (v1_job, v1_attempt) = flows::funded_running_job(&ledger, "v1trust").await;
    let mut v1 = flows::settle_params(v1_job, v1_attempt, 0x78, 800, 800, "v1trust");
    v1.signature_verified = false;
    v1.terminal_json = serde_json::json!({
        "protocol": "v1",
        "type": "inference_complete",
        "usage": {"prompt_tokens": 1200, "completion_tokens": 800, "reasoning_tokens": 0},
        "se_signature": "",
        "response_hash": "ab5e0001",
    });
    let outcome = ledger.settle(v1).await.expect("v1 settles");
    assert!(!outcome.flagged_for_review);
    assert_eq!(outcome.charged.get(), 4_000_000);
    assert_eq!(support::job_state(&db.pool, v1_job.get()).await, "settled");
}

/// Every mutation compares the live fencing epoch in-transaction; a bumped
/// epoch (another coordinator took ownership) yields `EpochFenced` and
/// moves nothing (plan §20).
#[tokio::test]
async fn epoch_fence_rejects_stale_coordinator() {
    if !support::pg_available() {
        support::skip();
        return;
    }
    let db = support::boot().await;
    support::set_epoch(&db.pool, 1).await;
    support::seed_consumer(&db.pool, CONSUMER, 10_000_000, 4_000_000).await;
    let ledger = support::ledger_at_epoch(&db.pool, 1);

    let (job, attempt) = flows::funded_running_job(&ledger, "fence").await;
    let before = support::balance_of(&db.pool, CONSUMER).await;

    // Another coordinator bumps the epoch behind this ledger's back.
    support::set_epoch(&db.pool, 2).await;

    let err = ledger
        .reserve(flows::reserve_params(
            &ledger,
            JobId::new(Uuid::new_v4()),
            1_000_000,
            "fenced",
        ))
        .await
        .expect_err("reserve must fence");
    assert!(matches!(err, LedgerError::EpochFenced), "got {err:?}");

    let err = ledger
        .settle(flows::settle_params(job, attempt, 0x77, 800, 800, "fenced"))
        .await
        .expect_err("settle must fence");
    assert!(matches!(err, LedgerError::EpochFenced), "got {err:?}");

    let err = ledger
        .release(darkbloom_server::contracts::ReleaseParams {
            operation_key: "op.release.fenced".to_owned(),
            job,
            reason: "x".to_owned(),
            coordinator_epoch: darkbloom_core::ids::CoordinatorEpoch::new(1),
        })
        .await
        .expect_err("release must fence");
    assert!(matches!(err, LedgerError::EpochFenced), "got {err:?}");

    let err = ledger
        .mark_running(job)
        .await
        .expect_err("mark_running must fence");
    assert!(matches!(err, LedgerError::EpochFenced), "got {err:?}");

    assert_eq!(support::balance_of(&db.pool, CONSUMER).await, before);
    assert_eq!(support::job_state(&db.pool, job.get()).await, "running");
}

/// API-key auth replicates the Go hash scheme (SHA-256 hex, store.HashKey)
/// against the legacy `api_keys` table, with negative caching and
/// disabled-key rejection.
#[tokio::test]
async fn api_key_store_validates_legacy_keys() {
    if !support::pg_available() {
        support::skip();
        return;
    }
    let db = support::boot().await;
    support::set_epoch(&db.pool, 1).await;
    let ledger = support::ledger_at_epoch(&db.pool, 1);

    let raw = "sk-darkbloom-test-123";
    sqlx::query(
        "INSERT INTO api_keys (key_hash, raw_prefix, owner_account_id, active, id, limit_micro_usd) \
         VALUES ($1, 'sk-dark', $2, TRUE, 'key_abc', 5000000)",
    )
    .bind(darkbloom_server::ledger::hash_key(raw))
    .bind(CONSUMER)
    .execute(&db.pool)
    .await
    .expect("insert key");

    let record = ledger.validate(raw).await.expect("key must validate");
    assert_eq!(record.key_id.as_str(), "key_abc");
    assert_eq!(record.spend_cap, Some(MicroUsd::new(5_000_000)));
    assert!(!record.disabled);
    assert_eq!(
        record.account,
        darkbloom_server::ledger::account_id_for(CONSUMER)
    );
    // The directory learned the reverse mapping during validation.
    assert_eq!(
        ledger.accounts().lookup(record.account).as_deref(),
        Some(CONSUMER)
    );

    // Cached second hit returns the same record.
    let cached = ledger.validate(raw).await.expect("cached validate");
    assert_eq!(cached.key_id.as_str(), "key_abc");

    assert!(ledger.validate("sk-unknown-token").await.is_none());

    let disabled_raw = "sk-darkbloom-disabled";
    sqlx::query(
        "INSERT INTO api_keys (key_hash, raw_prefix, owner_account_id, active, id) \
         VALUES ($1, 'sk-dark', $2, FALSE, 'key_off')",
    )
    .bind(darkbloom_server::ledger::hash_key(disabled_raw))
    .bind(CONSUMER)
    .execute(&db.pool)
    .await
    .expect("insert disabled key");
    assert!(ledger.validate(disabled_raw).await.is_none());
}
