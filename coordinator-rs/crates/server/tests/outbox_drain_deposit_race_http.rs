//! Concurrent outbox-drain + deposit vs clear-orphans (DECISIONS #83).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, Epoch};
use serde_json::json;
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
async fn concurrent_outbox_drain_acks_each_entry_once() {
    let state = pilot_app_state(true);
    {
        let mut box_ = state.outbox.lock().await;
        for i in 0..10 {
            let _ = box_.enqueue_critical(
                "inference.released",
                &json!({"job_id": format!("j{i}"), "n": i}).to_string(),
            );
        }
    }
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
                        .uri("/v1/admin/outbox-drain")
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await["acked_count"].as_u64().unwrap()
        }));
    }
    let mut total = 0u64;
    for h in handles {
        total += h.await.unwrap();
    }
    assert_eq!(total, 10);
    assert_eq!(state.outbox.lock().await.len(), 0);
    assert_eq!(state.outbox.lock().await.pending_under_retry_cap(), 0);
}

#[tokio::test]
async fn deposit_then_clear_orphans_conserves_balance() {
    let state = pilot_app_state(true);
    let epoch0 = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-dep-co".into()),
            "dep-co-res",
            "pilot-account",
            40_000,
            epoch0,
        )
        .unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-dep-co-h".into()),
            "dep-co-held",
            "pilot-account",
            60_000,
            epoch0,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch0, "dep-co-held", "pilot-account")
            .unwrap();
    }
    state.ownership.release();
    state.ownership.acquire(Epoch(13)).unwrap();

    let app = router(state.clone());

    // Deposit while orphans exist.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/deposits")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "event_id": "evt-dep-co-1",
                        "account": "pilot-account",
                        "amount_micro_usd": 200_000,
                        "withdrawable_micro_usd": 0
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

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
    let v = body_json(res).await;
    assert_eq!(v["released_count"], 1);
    assert_eq!(v["settled_count"], 1);
    // 1_000_000 start - 100k reserved + 200k deposit + 100k refunded = 1_200_000
    assert_eq!(v["balance_micro_usd"], 1_200_000);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        1_200_000
    );

    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/outbox-drain")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(body_json(res).await["ready"], true);
}
