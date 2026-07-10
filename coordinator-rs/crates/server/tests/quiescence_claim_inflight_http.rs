//! HTTP: claim without ack keeps quiescence not-ready (DECISIONS #35).

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
async fn claim_without_ack_keeps_quiescence_blocked() {
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
                        "event_id": "evt_inflight_q",
                        "amount_micro_usd": 25_000,
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
    assert_eq!(outbox.lock().await.in_flight_len(), 1);

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
        let _ = box_.ack_done(entry.id).unwrap();
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
    assert_eq!(body_json(q2).await["outbox_retryable"], 0);
}
