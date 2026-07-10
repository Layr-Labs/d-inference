//! Concurrent per-account clear-orphans + abort account_filter echo (DECISIONS #106).

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
async fn concurrent_per_account_clear_orphans_conserves_balance() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("nora", 300_000, 0).unwrap();
        led.credit("owen", 300_000, 0).unwrap();
        for (id, acct) in [
            ("pa-n1", "nora"),
            ("pa-n2", "nora"),
            ("pa-o1", "owen"),
            ("pa-o2", "owen"),
        ] {
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
    let app = Arc::new(router(state.clone()));
    let mut handles = Vec::new();
    for acct in ["nora", "owen"] {
        for _ in 0..3 {
            let app = app.clone();
            let acct = acct.to_string();
            handles.push(tokio::spawn(async move {
                let res = app
                    .as_ref()
                    .clone()
                    .oneshot(
                        Request::builder()
                            .method("POST")
                            .uri("/v1/admin/clear-orphans")
                            .header("content-type", "application/json")
                            .body(Body::from(
                                json!({ "account": acct, "actual_micro_usd": 0 }).to_string(),
                            ))
                            .unwrap(),
                    )
                    .await
                    .unwrap();
                assert_eq!(res.status(), StatusCode::OK);
                body_json(res).await
            }));
        }
    }
    let mut nora_settled = 0u64;
    let mut owen_settled = 0u64;
    for h in handles {
        let v = h.await.unwrap();
        let settled = v["settled_count"].as_u64().unwrap_or(0);
        match v["account_filter"].as_str() {
            Some("nora") => nora_settled += settled,
            Some("owen") => owen_settled += settled,
            _ => panic!("unexpected filter: {v}"),
        }
    }
    // Exactly two holds per account cleared across concurrent callers.
    assert_eq!(nora_settled, 2);
    assert_eq!(owen_settled, 2);
    assert_eq!(state.ledger.lock().await.balance("nora").0, 300_000);
    assert_eq!(state.ledger.lock().await.balance("owen").0, 300_000);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
}

#[tokio::test]
async fn account_filtered_abort_echoes_filter_and_scopes_remaining() {
    let _guard = lock_admin_batch_hook_tests();
    set_admin_batch_job_hook(None);
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("piper", 200_000, 0).unwrap();
        led.credit("quinn", 200_000, 0).unwrap();
        for (id, acct) in [("ae-p1", "piper"), ("ae-p2", "piper"), ("ae-q1", "quinn")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                25_000,
                epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(epoch, id, acct)
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
                .body(Body::from(r#"{"account":"piper","actual_micro_usd":0}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    set_admin_batch_job_hook(None);
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let abort = body_json(res).await;
    assert_eq!(abort["account_filter"], "piper");
    assert_eq!(abort["settled_count"], 1);
    let remaining: Vec<&str> = abort["remaining_held_start_authorized_job_ids"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    assert_eq!(remaining, vec!["ae-p2"]);
    assert_eq!(state.ledger.lock().await.held_start_authorized_count(), 2);
}
