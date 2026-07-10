//! Outbox-drain mid-flight ownership fence (DECISIONS #108).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{
    lock_outbox_drain_hook_tests, router, set_outbox_drain_entry_hook, Epoch,
};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
async fn outbox_drain_aborts_mid_flight_on_ownership_steal() {
    let _guard = lock_outbox_drain_hook_tests();
    set_outbox_drain_entry_hook(None);
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    {
        let mut box_ = state.outbox.lock().await;
        for i in 0..4 {
            let _ = box_.enqueue_critical(
                "inference.settled",
                &format!(r#"{{"job_id":"od-{i}"}}"#),
            );
        }
    }
    assert!(state.outbox.lock().await.len() >= 4);

    let gate = ownership.clone();
    let seen = Arc::new(AtomicUsize::new(0));
    let seen2 = seen.clone();
    set_outbox_drain_entry_hook(Some(Arc::new(move |_kind| {
        if seen2.fetch_add(1, Ordering::SeqCst) == 1 {
            gate.release();
        }
    })));

    let app = router(state.clone());
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
    set_outbox_drain_entry_hook(None);
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let abort = body_json(res).await;
    assert_eq!(abort["action"], "outbox_drain_aborted");
    assert_eq!(abort["acked_count"], 2);
    assert!(abort["outbox_retryable"].as_u64().unwrap() >= 2);
    assert_eq!(abort["ready"], false);

    // Resume after re-acquire.
    ownership.acquire(Epoch(ownership.epoch().0 + 1)).unwrap();
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
    assert_eq!(v["outbox_retryable"], 0);

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
    assert_eq!(body_json(q).await["ready"], true);
}

#[tokio::test]
async fn concurrent_outbox_drain_after_partial_abort_reaches_ready() {
    let _guard = lock_outbox_drain_hook_tests();
    set_outbox_drain_entry_hook(None);
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    {
        let mut box_ = state.outbox.lock().await;
        for i in 0..6 {
            let _ = box_.enqueue_critical(
                "billing.deposit_applied",
                &format!(r#"{{"event_id":"e-{i}"}}"#),
            );
        }
    }
    let gate = ownership.clone();
    let seen = Arc::new(AtomicUsize::new(0));
    let seen2 = seen.clone();
    set_outbox_drain_entry_hook(Some(Arc::new(move |_kind| {
        if seen2.fetch_add(1, Ordering::SeqCst) == 0 {
            gate.release();
        }
    })));

    let app = Arc::new(router(state.clone()));
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
    set_outbox_drain_entry_hook(None);
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(res).await["acked_count"], 1);

    ownership.acquire(Epoch(99)).unwrap();
    let mut handles = Vec::new();
    for _ in 0..4 {
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
            body_json(res).await["acked_count"].as_u64().unwrap_or(0)
        }));
    }
    let mut total = 0u64;
    for h in handles {
        total += h.await.unwrap();
    }
    // Remaining 5 entries acked exactly once across concurrent drains.
    assert_eq!(total, 5);
    assert_eq!(state.outbox.lock().await.pending_under_retry_cap(), 0);
}
