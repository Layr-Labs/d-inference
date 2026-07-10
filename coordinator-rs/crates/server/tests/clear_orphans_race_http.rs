//! Concurrent clear-orphans + quiescence orphan_summary (DECISIONS #81).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, Epoch};
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
async fn quiescence_orphan_summary_counts_needs_adopt() {
    let state = pilot_app_state(true);
    let epoch0 = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-sum-a".into()),
            "sum-res",
            "pilot-account",
            20_000,
            epoch0,
        )
        .unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-sum-b".into()),
            "sum-held",
            "pilot-account",
            30_000,
            epoch0,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch0, "sum-held", "pilot-account")
            .unwrap();
    }
    state.ownership.release();
    state.ownership.acquire(Epoch(7)).unwrap();

    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let v = body_json(res).await;
    assert_eq!(v["orphan_summary"]["needs_adopt_count"], 2);
    assert_eq!(v["orphan_summary"]["reserved_not_started_count"], 1);
    assert_eq!(v["orphan_summary"]["held_start_authorized_count"], 1);
}

#[tokio::test]
async fn concurrent_clear_orphans_conserves_money_and_is_idempotent() {
    let state = pilot_app_state(true);
    let epoch0 = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for (id, amt, hold) in [
            ("race-res", 25_000, false),
            ("race-held", 35_000, true),
        ] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                "pilot-account",
                amt,
                epoch0,
            )
            .unwrap();
            if hold {
                led.mark_start_authorized_fenced(epoch0, id, "pilot-account")
                    .unwrap();
            }
        }
    }
    state.ownership.release();
    state.ownership.acquire(Epoch(11)).unwrap();

    let app = Arc::new(router(state.clone()));
    let mut handles = Vec::new();
    for _ in 0..8 {
        let app = app.clone();
        handles.push(tokio::spawn(async move {
            let res = app
                .as_ref()
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/clear-orphans")
                        .header("content-type", "application/json")
                        .body(Body::from("{}"))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await
        }));
    }
    let mut total_released = 0usize;
    let mut total_settled = 0usize;
    for h in handles {
        let v = h.await.unwrap();
        total_released += v["released_count"].as_u64().unwrap_or(0) as usize;
        total_settled += v["settled_count"].as_u64().unwrap_or(0) as usize;
    }
    // Exactly one pass does the work; others see already-cleared.
    assert_eq!(total_released, 1);
    assert_eq!(total_settled, 1);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        1_000_000
    );

    // Idempotent follow-up.
    let res = app
        .as_ref()
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/clear-orphans")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    let v = body_json(res).await;
    assert_eq!(v["adopted_count"], 0);
    assert_eq!(v["released_count"], 0);
    assert_eq!(v["settled_count"], 0);
}

#[tokio::test]
async fn clear_orphans_then_ack_outbox_makes_quiescence_ready() {
    let state = pilot_app_state(true);
    let epoch0 = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-q".into()),
            "q-res",
            "pilot-account",
            10_000,
            epoch0,
        )
        .unwrap();
    }
    state.ownership.release();
    state.ownership.acquire(Epoch(3)).unwrap();

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/clear-orphans")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(body_json(res).await["released_count"], 1);

    // Critical outbox still blocks ready.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let q = body_json(res).await;
    assert_eq!(q["active_jobs"], 0);
    assert_eq!(q["ready"], false);
    assert!(q["outbox_retryable"].as_u64().unwrap() > 0);

    // Ack all outbox entries.
    {
        let mut box_ = state.outbox.lock().await;
        while let Some(e) = box_.try_claim() {
            let _ = box_.ack_done(e.id);
        }
    }

    let res = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let q = body_json(res).await;
    assert_eq!(q["ready"], true);
    assert_eq!(q["orphan_summary"]["needs_adopt_count"], 0);
    assert_eq!(q["orphan_summary"]["reserved_not_started_count"], 0);
    assert_eq!(q["orphan_summary"]["held_start_authorized_count"], 0);
}
