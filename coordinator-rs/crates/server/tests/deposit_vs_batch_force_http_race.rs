//! Deposit vs batch recover/force conservation + abort remaining ids (DECISIONS #98).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{
    lock_admin_batch_hook_tests, router, set_admin_batch_job_hook,
};
use serde_json::json;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
async fn concurrent_deposit_and_force_settle_batch_conserves_balance() {
    // Serialize against ADMIN_BATCH_JOB_HOOK users (DECISIONS #98 flake).
    let _guard = lock_admin_batch_hook_tests();
    set_admin_batch_job_hook(None);

    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-dfs".into()),
            "dfs-held",
            "pilot-account",
            200_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "dfs-held", "pilot-account")
            .unwrap();
    }

    let app = Arc::new(router(state.clone()));
    let mut deposit_handles = Vec::new();
    let mut settle_handles = Vec::new();

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
                                "event_id": format!("evt-dfs-{i}"),
                                "amount_micro_usd": 50_000,
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
        settle_handles.push(tokio::spawn(async move {
            let res = app
                .as_ref()
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/force-settle-batch")
                        .header("content-type", "application/json")
                        .body(Body::from(r#"{"actual_micro_usd":0}"#))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await["settled_count"].as_u64().unwrap_or(0)
        }));
    }

    let mut applied = 0usize;
    for h in deposit_handles {
        if h.await.unwrap() {
            applied += 1;
        }
    }
    let mut settled = 0u64;
    for h in settle_handles {
        settled += h.await.unwrap();
    }
    assert_eq!(applied, 4);
    assert_eq!(settled, 1);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        1_000_000 + 200_000
    );
}

#[tokio::test]
async fn batch_abort_includes_remaining_job_ids() {
    let _guard = lock_admin_batch_hook_tests();
    set_admin_batch_job_hook(None);
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for id in ["rem-a", "rem-b", "rem-c"] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                "pilot-account",
                30_000,
                epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(epoch, id, "pilot-account")
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
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle-batch")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"actual_micro_usd":0}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    set_admin_batch_job_hook(None);

    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v = body_json(res).await;
    assert_eq!(v["action"], "force_settle_batch_aborted");
    assert_eq!(v["settled_count"], 1);
    assert_eq!(v["active_jobs"], 2);
    assert_eq!(v["held_start_authorized"], 2);
    let remaining = v["remaining_held_start_authorized_job_ids"]
        .as_array()
        .unwrap();
    assert_eq!(remaining.len(), 2);
}
