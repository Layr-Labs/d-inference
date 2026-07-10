//! Admin outbox-drain for cutover readiness (DECISIONS #82).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, Epoch};
use tower::ServiceExt;

#[tokio::test]
async fn clear_orphans_then_outbox_drain_makes_ready() {
    let state = pilot_app_state(true);
    let epoch0 = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-drain".into()),
            "drain-res",
            "pilot-account",
            15_000,
            epoch0,
        )
        .unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-drain-h".into()),
            "drain-held",
            "pilot-account",
            20_000,
            epoch0,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch0, "drain-held", "pilot-account")
            .unwrap();
    }
    state.ownership.release();
    state.ownership.acquire(Epoch(5)).unwrap();

    let app = router(state);
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
    assert_eq!(body_json(res).await["ready"], false);

    let res = app
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
    let v = body_json(res).await;
    assert_eq!(v["action"], "outbox_drained");
    assert!(v["acked_count"].as_u64().unwrap() >= 2);
    assert_eq!(v["ready"], true);
    assert_eq!(v["outbox_retryable"], 0);

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
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(body_json(res).await["ready"], true);
}

#[tokio::test]
async fn outbox_drain_rejects_without_ownership() {
    let state = pilot_app_state(false);
    let app = router(state);
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
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
}

#[tokio::test]
async fn outbox_drain_idempotent_when_empty() {
    let state = pilot_app_state(true);
    let app = router(state);
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
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["acked_count"], 0);
    assert_eq!(v["ready"], true);
}
