//! Multi-account remaining-id clear + terminal-ingest after force (DECISIONS #104).

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
async fn multi_account_remaining_ids_force_settle_then_ingest() {
    let _guard = lock_admin_batch_hook_tests();
    set_admin_batch_job_hook(None);
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("helen", 500_000, 0).unwrap();
        led.credit("ivan", 500_000, 0).unwrap();
        for (id, acct) in [("ma-a", "helen"), ("ma-b", "ivan"), ("ma-c", "helen")] {
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
                .uri("/v1/admin/force-settle-batch")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"actual_micro_usd":0}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    set_admin_batch_job_hook(None);
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let abort = body_json(res).await;
    assert_eq!(abort["settled_count"], 1);
    let remaining: Vec<String> = abort["remaining_held_start_authorized_job_ids"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect();
    assert_eq!(remaining.len(), 2);

    ownership.acquire(Epoch(epoch + 40)).unwrap();
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
                .uri("/v1/admin/force-settle-batch")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_ids": remaining,
                        "actual_micro_usd": 0
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(body_json(res).await["settled_count"], 2);
    assert_eq!(state.ledger.lock().await.balance("helen").0, 500_000);
    assert_eq!(state.ledger.lock().await.balance("ivan").0, 500_000);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);

    // Terminal ingest of force_settled disposition is ACK / already settled — no double charge.
    for job_id in &remaining {
        let digest = format!("force-settle-batch:{job_id}");
        let res = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/admin/terminal-ingest")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        json!({
                            "job_id": job_id,
                            "attempt_id": "force-settle",
                            "terminal_digest": digest,
                            "lease_id": "",
                            "se_signature": ""
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let v = body_json(res).await;
        assert_eq!(v["disposition"], "force_settled");
        assert_eq!(v["type"], "terminal_ack");
    }
    // Balances unchanged by ingest replay.
    assert_eq!(state.ledger.lock().await.balance("helen").0, 500_000);
    assert_eq!(state.ledger.lock().await.balance("ivan").0, 500_000);
}

#[tokio::test]
async fn held_review_batch_vs_recover_batch_never_releases_held() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-hrr".into()),
            "hrr-held",
            "pilot-account",
            60_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "hrr-held", "pilot-account")
            .unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-hrr2".into()),
            "hrr-res",
            "pilot-account",
            40_000,
            epoch,
        )
        .unwrap();
    }
    let bal_before = state.ledger.lock().await.balance("pilot-account").0;
    let app = Arc::new(router(state.clone()));

    let mut review_handles = Vec::new();
    let mut recover_handles = Vec::new();
    for _ in 0..6 {
        let app = app.clone();
        review_handles.push(tokio::spawn(async move {
            let res = app
                .as_ref()
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/held-review-batch")
                        .header("content-type", "application/json")
                        .body(Body::from("{}"))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await
        }));
    }
    for _ in 0..4 {
        let app = app.clone();
        recover_handles.push(tokio::spawn(async move {
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
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await["released_count"].as_u64().unwrap_or(0)
        }));
    }

    for h in review_handles {
        let v = h.await.unwrap();
        assert!(v.get("refunded_micro_usd").is_none());
    }
    let mut released = 0u64;
    for h in recover_handles {
        released += h.await.unwrap();
    }
    // Only reserved job released; held remains.
    assert_eq!(released, 1);
    assert_eq!(state.ledger.lock().await.held_start_authorized_count(), 1);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        bal_before + 40_000
    );
}
