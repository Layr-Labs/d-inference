//! Retry-exhausted outbox rows block quiescence ready (DECISIONS #133).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{
    lock_outbox_drain_hook_tests, router, set_outbox_drain_entry_hook,
};
use serde_json::json;
use tower::ServiceExt;

#[tokio::test]
async fn exhausted_outbox_keeps_quiescence_not_ready() {
    let state = pilot_app_state(true);
    {
        let mut box_ = state.outbox.lock().await;
        box_
            .enqueue_critical("billing.deposit_applied", r#"{"event_id":"evt-ex"}"#)
            .unwrap();
        assert!(box_.force_exhaust_one_for_test());
        assert_eq!(box_.pending_under_retry_cap(), 0);
        assert_eq!(box_.pending_blocked(), 1);
        assert_eq!(box_.len(), 1);
    }

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v = body_json(res).await;
    assert_eq!(v["ready"], false);
    assert_eq!(v["outbox_pending"], 1);
    assert_eq!(v["outbox_retryable"], 0);
    assert_eq!(v["outbox_blocked"], 1);
    assert_eq!(v["cutover_hint"], "outbox-drain");
}

#[tokio::test]
async fn outbox_drain_clears_exhausted_and_becomes_ready() {
    let _guard = lock_outbox_drain_hook_tests();
    set_outbox_drain_entry_hook(None);

    let state = pilot_app_state(true);
    {
        let mut box_ = state.outbox.lock().await;
        box_
            .enqueue_critical("inference.settled", r#"{"job":"ex-1"}"#)
            .unwrap();
        assert!(box_.force_exhaust_one_for_test());
    }

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/outbox-drain")
                .header("content-type", "application/json")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["acked_count"], 1);
    assert_eq!(v["ready"], true);
    assert_eq!(v["outbox_pending"], 0);
    assert!(state.outbox.lock().await.is_empty());

    let q = app
        .oneshot(
            Request::builder()
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(q.status(), StatusCode::OK);
    let qv = body_json(q).await;
    assert_eq!(qv["ready"], true);
    assert_eq!(qv["outbox_blocked"], 0);
    assert_eq!(qv["cutover_hint"], "ready");
}

#[tokio::test]
async fn cutover_drain_all_drains_exhausted_outbox() {
    let _guard = lock_outbox_drain_hook_tests();
    set_outbox_drain_entry_hook(None);

    let state = pilot_app_state(true);
    {
        let mut box_ = state.outbox.lock().await;
        box_
            .enqueue_critical("billing.deposit_applied", r#"{"n":1}"#)
            .unwrap();
        assert!(box_.force_exhaust_one_for_test());
    }

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain-all")
                .header("content-type", "application/json")
                .body(Body::from(json!({}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["ready"], true);
    assert!(state.outbox.lock().await.is_empty());
}
