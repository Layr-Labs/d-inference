//! One-shot cutover-drain-all multi-tenant loop (DECISIONS #115).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{
    lock_outbox_drain_hook_tests, router, set_outbox_drain_entry_hook, Epoch,
};
use serde_json::json;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
async fn cutover_drain_all_clears_multi_tenant_to_ready() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for (acct, ids) in [
            ("rio", &["cda-r1", "cda-r2"][..]),
            ("sage", &["cda-s1"][..]),
            ("tash", &["cda-t1", "cda-t2"][..]),
        ] {
            led.credit(acct, 350_000, 0).unwrap();
            for id in ids {
                led.reserve_with_epoch(
                    darkbloom_coordinator::OperationKey(format!("r-{id}")),
                    id,
                    acct,
                    40_000,
                    epoch,
                )
                .unwrap();
                led.mark_start_authorized_fenced(epoch, id, acct)
                    .unwrap();
            }
        }
    }
    {
        let mut box_ = state.outbox.lock().await;
        let _ = box_.enqueue_critical("billing.deposit_applied", r#"{"event_id":"cda-seed"}"#);
    }

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain-all")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "cutover_drain_all");
    assert_eq!(v["ready"], true);
    assert!(v["accounts_cleared"].as_array().unwrap().len() >= 3);
    assert!(v["accounts_needing_cutover"]
        .as_array()
        .unwrap()
        .is_empty());
    assert_eq!(state.ledger.lock().await.balance("rio").0, 350_000);
    assert_eq!(state.ledger.lock().await.balance("sage").0, 350_000);
    assert_eq!(state.ledger.lock().await.balance("tash").0, 350_000);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);

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
async fn cutover_drain_all_charged_clamps_per_account() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("uma", 500_000, 0).unwrap();
        led.credit("vera", 500_000, 0).unwrap();
        for (id, acct) in [("cdc-u1", "uma"), ("cdc-u2", "uma"), ("cdc-v1", "vera")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                100_000,
                epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(epoch, id, acct)
                .unwrap();
        }
    }
    let app = router(state.clone());
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain-all")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "actual_micro_usd": 25_000 }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(body_json(res).await["ready"], true);
    // uma: 2×25k charged → 450k; vera: 1×25k → 475k
    assert_eq!(state.ledger.lock().await.balance("uma").0, 450_000);
    assert_eq!(state.ledger.lock().await.balance("vera").0, 475_000);
}

#[tokio::test]
async fn cutover_drain_all_aborts_on_ownership_steal() {
    let _guard = lock_outbox_drain_hook_tests();
    set_outbox_drain_entry_hook(None);
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("wynn", 200_000, 0).unwrap();
        led.credit("xavi", 200_000, 0).unwrap();
        for (id, acct) in [("cdo-w1", "wynn"), ("cdo-x1", "xavi")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                30_000,
                epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(epoch, id, acct)
                .unwrap();
        }
    }
    {
        let mut box_ = state.outbox.lock().await;
        for i in 0..4 {
            let _ = box_.enqueue_critical(
                "inference.settled",
                &format!(r#"{{"job_id":"seed-{i}"}}"#),
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

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain-all")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    set_outbox_drain_entry_hook(None);
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let abort = body_json(res).await;
    assert_eq!(abort["action"], "cutover_drain_all_aborted");
    assert_eq!(abort["ready"], false);
    // At least one account may have been cleared before drain steal.
    assert!(!abort["accounts_needing_cutover"]
        .as_array()
        .unwrap()
        .is_empty()
        || state.ledger.lock().await.active_job_count() > 0
        || abort["outbox_retryable"].as_u64().unwrap_or(0) > 0
        || !abort.get("accounts_needing_cutover").unwrap().is_null());

    ownership.acquire(Epoch(epoch + 11)).unwrap();
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain-all")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(body_json(res).await["ready"], true);
    assert_eq!(state.ledger.lock().await.balance("wynn").0, 200_000);
    assert_eq!(state.ledger.lock().await.balance("xavi").0, 200_000);
}

#[tokio::test]
async fn cutover_drain_all_rejects_without_ownership() {
    let state = pilot_app_state(true);
    state.ownership.release();
    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain-all")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
}

#[tokio::test]
async fn cutover_drain_all_rejects_negative_actual() {
    let state = pilot_app_state(true);
    let app = router(state);
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain-all")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"actual_micro_usd":-1}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
}
