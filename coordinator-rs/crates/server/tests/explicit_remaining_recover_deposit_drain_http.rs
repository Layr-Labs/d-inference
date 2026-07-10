//! Explicit remaining-id recover after batch abort (DECISIONS #103).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{
    lock_admin_batch_hook_tests, router, set_admin_batch_job_hook, Epoch,
};
use serde_json::json;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
async fn recover_batch_explicit_remaining_ids_after_abort() {
    let _guard = lock_admin_batch_hook_tests();
    set_admin_batch_job_hook(None);
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for id in ["xrr-a", "xrr-b", "xrr-c"] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                "pilot-account",
                35_000,
                epoch,
            )
            .unwrap();
        }
    }

    let gate = ownership.clone();
    let seen = Arc::new(AtomicUsize::new(0));
    let seen2 = seen.clone();
    set_admin_batch_job_hook(Some(Arc::new(move |_job| {
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
                .uri("/v1/admin/recover-undispatched-batch")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    set_admin_batch_job_hook(None);
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let abort = body_json(res).await;
    assert_eq!(abort["released_count"], 1);
    assert_eq!(abort["refunded_micro_usd"], 35_000);
    let remaining: Vec<String> = abort["remaining_active_job_ids"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect();
    assert_eq!(remaining.len(), 2);

    ownership.acquire(Epoch(epoch + 30)).unwrap();
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/adopt-jobs")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_ids": remaining }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(body_json(res).await["adopted_count"], 2);

    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/recover-undispatched-batch")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "job_ids": remaining }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["released_count"], 2);
    assert_eq!(v["active_jobs"], 0);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        1_000_000
    );

    // Quiescence ready after outbox drain.
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

#[tokio::test]
async fn concurrent_deposit_and_outbox_drain_after_recover() {
    // Hold batch hook lock so a parallel steal-hook test cannot fire into recover.
    let _guard = lock_admin_batch_hook_tests();
    set_admin_batch_job_hook(None);
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-dod".into()),
            "dod-res",
            "pilot-account",
            50_000,
            epoch,
        )
        .unwrap();
    }
    let app = Arc::new(router(state.clone()));

    // Recover first so outbox has inference.released.
    let res = app
        .as_ref()
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/recover-undispatched-batch")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(body_json(res).await["released_count"], 1);
    assert!(state.outbox.lock().await.pending_under_retry_cap() > 0);

    let mut deposit_handles = Vec::new();
    let mut drain_handles = Vec::new();
    for i in 0..4 {
        let app = app.clone();
        deposit_handles.push(tokio::spawn(async move {
            let res = app
                .as_ref()
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/deposits")
                        .header("content-type", "application/json")
                        .body(Body::from(
                            json!({
                                "event_id": format!("evt-dod-{i}"),
                                "amount_micro_usd": 10_000,
                                "withdrawable_micro_usd": 0
                            })
                            .to_string(),
                        ))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await["applied"].as_bool().unwrap()
        }));
    }
    for _ in 0..4 {
        let app = app.clone();
        drain_handles.push(tokio::spawn(async move {
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
            body_json(res).await
        }));
    }

    let mut applied = 0usize;
    for h in deposit_handles {
        if h.await.unwrap() {
            applied += 1;
        }
    }
    let mut ready_seen = false;
    for h in drain_handles {
        let v = h.await.unwrap();
        if v["ready"].as_bool().unwrap_or(false) {
            ready_seen = true;
        }
    }
    assert_eq!(applied, 4);
    assert!(ready_seen);
    // Deposits may leave critical outbox entries; drain should clear all.
    assert_eq!(state.outbox.lock().await.pending_under_retry_cap(), 0);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        1_000_000 + 40_000
    );
}
