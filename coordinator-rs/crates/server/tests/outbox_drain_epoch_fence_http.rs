//! Outbox-drain binds to start fencing epoch (DECISIONS #135).

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
async fn outbox_drain_aborts_on_epoch_reacquire_mid_flight() {
    let _guard = lock_outbox_drain_hook_tests();
    set_outbox_drain_entry_hook(None);

    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let start_epoch = ownership.epoch().0;
    {
        let mut box_ = state.outbox.lock().await;
        for i in 0..4 {
            let _ = box_.enqueue_critical(
                "inference.settled",
                &format!(r#"{{"job_id":"oe-{i}"}}"#),
            );
        }
    }

    let gate = ownership.clone();
    let seen = Arc::new(AtomicUsize::new(0));
    let seen2 = seen.clone();
    set_outbox_drain_entry_hook(Some(Arc::new(move |_kind| {
        // After first ack: release and re-acquire with a new epoch while
        // still "holding" — drain must abort on epoch mismatch.
        if seen2.fetch_add(1, Ordering::SeqCst) == 0 {
            gate.release();
            gate.acquire(Epoch(start_epoch + 11)).unwrap();
        }
    })));

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
    set_outbox_drain_entry_hook(None);

    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v = body_json(res).await;
    assert_eq!(v["action"], "outbox_drain_aborted");
    assert_eq!(v["error"]["code"], "ownership_lost");
    assert_eq!(v["drain_epoch"], start_epoch);
    assert_eq!(v["acked_count"], 1);
    // Remaining entries must still be present — not silently dropped.
    assert!(state.outbox.lock().await.len() >= 3);
    assert_eq!(v["ready"], false);
}

#[tokio::test]
async fn outbox_drain_success_includes_drain_epoch_not_required() {
    let _guard = lock_outbox_drain_hook_tests();
    set_outbox_drain_entry_hook(None);

    let state = pilot_app_state(true);
    {
        let mut box_ = state.outbox.lock().await;
        let _ = box_.enqueue_critical("billing.deposit_applied", r#"{"n":1}"#);
    }
    let app = router(state.clone());
    let res = app
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
    assert!(state.outbox.lock().await.is_empty());
}
