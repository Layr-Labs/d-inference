//! Concurrent outbox requeue after partial drain keeps quiescence not-ready.

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use serde_json::json;
use tower::ServiceExt;

fn test_state() -> darkbloom_coordinator::AppState {
    pilot_app_state(true)
}

#[tokio::test]
async fn deposit_claim_requeue_keeps_quiescence_blocked_then_ack_clears() {
    let state = test_state();
    let outbox = state.outbox.clone();
    let app = router(state);

    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/deposits")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "event_id": "evt_requeue_q",
                        "amount_micro_usd": 40_000,
                        "withdrawable_micro_usd": 0
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let entry = {
        let mut box_ = outbox.lock().await;
        box_.try_claim().unwrap()
    };
    // Claim is non-destructive until ack — still occupied / not ready.
    assert!(!outbox.lock().await.is_empty());
    assert_eq!(outbox.lock().await.in_flight_len(), 1);
    {
        let mut box_ = outbox.lock().await;
        box_.requeue(entry).unwrap();
    }

    let q1 = app
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
    assert_eq!(q1.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(q1).await["outbox_retryable"], 1);

    {
        let mut box_ = outbox.lock().await;
        let e = box_.try_claim().unwrap();
        let _ = box_.ack_done(e.id);
    }
    let q2 = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(q2.status(), StatusCode::OK);
    assert_eq!(body_json(q2).await["ready"], true);
}
