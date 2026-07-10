//! Explicit remaining-id batch clear after abort + cancel vs force (DECISIONS #102).

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
async fn force_settle_batch_explicit_remaining_ids_after_abort() {
    let _guard = lock_admin_batch_hook_tests();
    set_admin_batch_job_hook(None);
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for id in ["xid-a", "xid-b", "xid-c"] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                "pilot-account",
                40_000,
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

    ownership.acquire(Epoch(epoch + 20)).unwrap();
    // Adopt then force-settle only the remaining ids from the abort payload.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/adopt-jobs")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "job_ids": remaining }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(body_json(res).await["adopted_count"], 2);

    let res = app
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
    let v = body_json(res).await;
    assert_eq!(v["settled_count"], 2);
    assert_eq!(v["active_jobs"], 0);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        1_000_000
    );
}

#[tokio::test]
async fn cancel_attempt_never_releases_while_force_settle_races() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-cafs".into()),
            "cafs-held",
            "pilot-account",
            80_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "cafs-held", "pilot-account")
            .unwrap();
    }
    let bal_before = state.ledger.lock().await.balance("pilot-account").0;

    let app = Arc::new(router(state.clone()));
    let mut cancel_handles = Vec::new();
    let mut settle_handles = Vec::new();

    for _ in 0..6 {
        let app = app.clone();
        cancel_handles.push(tokio::spawn(async move {
            let res = app
                .as_ref()
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/v1/admin/cancel-attempt")
                        .header("content-type", "application/json")
                        .body(Body::from(
                            json!({
                                "job_id": "cafs-held",
                                "attempt_id": "att-1",
                                "lease_id": "lease-1",
                                "provider_id": "prov-1"
                            })
                            .to_string(),
                        ))
                        .unwrap(),
                )
                .await
                .unwrap();
            // Provider may be missing (502) or cancel accepted (200) — never a money move.
            let status = res.status();
            let v = body_json(res).await;
            assert!(
                status == StatusCode::OK
                    || status == StatusCode::BAD_GATEWAY
                    || status == StatusCode::CONFLICT
            );
            assert!(v.get("refunded_micro_usd").is_none());
            assert!(v.get("charged_micro_usd").is_none());
            v
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
                        .uri("/v1/admin/force-settle")
                        .header("content-type", "application/json")
                        .body(Body::from(
                            r#"{"job_id":"cafs-held","actual_micro_usd":20000}"#,
                        ))
                        .unwrap(),
                )
                .await
                .unwrap();
            body_json(res).await
        }));
    }

    for h in cancel_handles {
        let _ = h.await.unwrap();
    }
    let mut released = 0usize;
    for h in settle_handles {
        let v = h.await.unwrap();
        if v["action"] == "released" {
            released += 1;
        }
    }
    assert_eq!(released, 1);
    // Charged 20k → bal = bal_before + 60k refund
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        bal_before + 60_000
    );
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
}
