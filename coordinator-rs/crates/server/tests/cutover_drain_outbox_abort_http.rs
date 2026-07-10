//! cutover-drain preserves clear results when outbox-drain aborts (DECISIONS #109).

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
async fn cutover_drain_preserves_clear_when_outbox_drain_aborts() {
    let _guard = lock_outbox_drain_hook_tests();
    set_outbox_drain_entry_hook(None);
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for id in ["cd-a", "cd-b"] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                "pilot-account",
                50_000,
                epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(epoch, id, "pilot-account")
                .unwrap();
        }
    }
    // Seed extra outbox entries so drain has work after clear enqueues settles.
    {
        let mut box_ = state.outbox.lock().await;
        for i in 0..3 {
            let _ = box_.enqueue_critical(
                "billing.deposit_applied",
                &format!(r#"{{"event_id":"seed-{i}"}}"#),
            );
        }
    }

    let gate = ownership.clone();
    let seen = Arc::new(AtomicUsize::new(0));
    let seen2 = seen.clone();
    set_outbox_drain_entry_hook(Some(Arc::new(move |_kind| {
        // Steal after first outbox ack during the drain phase.
        if seen2.fetch_add(1, Ordering::SeqCst) == 0 {
            gate.release();
        }
    })));

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"actual_micro_usd":0}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    set_outbox_drain_entry_hook(None);
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let abort = body_json(res).await;
    assert_eq!(abort["action"], "cutover_drain_aborted");
    assert_eq!(abort["phase"], "outbox_drain");
    assert_eq!(abort["ready"], false);
    // Clear phase completed — money restored, jobs gone.
    assert_eq!(abort["clear_orphans"]["settled_count"], 2);
    assert_eq!(abort["clear_orphans"]["active_jobs"], 0);
    assert_eq!(state.ledger.lock().await.balance("pilot-account").0, 1_000_000);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
    // Partial drain progress preserved.
    assert!(abort["acked_count"].as_u64().unwrap() >= 1);
    assert!(abort["outbox_retryable"].as_u64().unwrap() >= 1);
    assert!(abort["outbox_drain"]["action"] == "outbox_drain_aborted");

    // Quiescence hints outbox-drain (jobs cleared, outbox remains).
    let q = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(q.status(), StatusCode::SERVICE_UNAVAILABLE);
    let qv = body_json(q).await;
    assert_eq!(qv["ready"], false);
    assert_eq!(qv["active_jobs"], 0);
    assert_eq!(qv["cutover_hint"], "outbox-drain");

    // Resume: re-acquire + outbox-drain reaches ready.
    ownership.acquire(Epoch(epoch + 20)).unwrap();
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
    assert_eq!(body_json(res).await["outbox_retryable"], 0);

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
async fn cutover_drain_resume_after_drain_abort_via_cutover_again() {
    let _guard = lock_outbox_drain_hook_tests();
    set_outbox_drain_entry_hook(None);
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-cd2".into()),
            "cd2-held",
            "pilot-account",
            40_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "cd2-held", "pilot-account")
            .unwrap();
    }
    {
        let mut box_ = state.outbox.lock().await;
        for i in 0..4 {
            let _ = box_.enqueue_critical(
                "inference.released",
                &format!(r#"{{"job_id":"seed-{i}"}}"#),
            );
        }
    }

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
                .uri("/v1/admin/cutover-drain")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    set_outbox_drain_entry_hook(None);
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(res).await["phase"], "outbox_drain");
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);

    ownership.acquire(Epoch(epoch + 30)).unwrap();
    // Second cutover-drain: clear is no-op, drain finishes.
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "cutover_drained");
    assert_eq!(v["ready"], true);
    assert_eq!(v["outbox_retryable"], 0);
}
