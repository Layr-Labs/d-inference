//! adopt-job / cancel-attempt / cutover-drain-all remaining accounts (DECISIONS #128).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{
    lock_clear_orphans_hook_tests, router, set_clear_orphans_phase_hook, Epoch,
};
use serde_json::json;
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
async fn adopt_job_returns_remaining_accounts() {
    // Serialize against clear-orphans hook users in this binary.
    let _guard = lock_clear_orphans_hook_tests();
    set_clear_orphans_phase_hook(None);

    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let old = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("cleo", 160_000, 0).unwrap();
        led.credit("drew", 160_000, 0).unwrap();
        for (id, acct) in [("aj1-c", "cleo"), ("aj1-d", "drew")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                30_000,
                old,
            )
            .unwrap();
            led.mark_start_authorized_fenced(old, id, acct).unwrap();
        }
    }
    ownership.release();
    ownership.acquire(Epoch(old + 11)).unwrap();

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/adopt-job")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_id": "aj1-c" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "adopted");
    assert_eq!(v["needs_adopt_count"], 1); // drew still stale
    let mut accounts = v["accounts_needing_cutover"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    accounts.sort();
    assert_eq!(accounts, vec!["cleo".to_string(), "drew".to_string()]);
    assert_eq!(v["held_start_authorized"], 2);

    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/adopt-jobs")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(body_json(res).await["needs_adopt_count"], 0);

    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain-all")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "actual_micro_usd": 0, "accounts": accounts }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["ready"], true);
    assert_eq!(v["needs_adopt_count"], 0);
    assert_eq!(state.ledger.lock().await.balance("cleo").0, 160_000);
    assert_eq!(state.ledger.lock().await.balance("drew").0, 160_000);
}

#[tokio::test]
async fn cancel_attempt_returns_remaining_accounts() {
    let _guard = lock_clear_orphans_hook_tests();
    set_clear_orphans_phase_hook(None);

    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("eden", 140_000, 0).unwrap();
        led.credit("faye", 140_000, 0).unwrap();
        for (id, acct) in [("ca-e1", "eden"), ("ca-f1", "faye")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                35_000,
                epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(epoch, id, acct).unwrap();
        }
    }

    let app = router(state.clone());
    let bal_e = state.ledger.lock().await.balance("eden").0;
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cancel-attempt")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "ca-e1",
                        "attempt_id": "a1",
                        "lease_id": "l1",
                        "provider_id": "p1",
                        "dispatch_nonce": "n1",
                        "request_digest": "sha256:req"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "cancelled_await_terminal");
    assert_eq!(v["needs_adopt_count"], 0);
    let mut accounts = v["accounts_needing_cutover"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    accounts.sort();
    assert_eq!(accounts, vec!["eden".to_string(), "faye".to_string()]);
    assert_eq!(state.ledger.lock().await.balance("eden").0, bal_e);
    assert_eq!(v["held_start_authorized"], 2);
}

#[tokio::test]
async fn cutover_drain_all_success_includes_needs_adopt() {
    let _guard = lock_clear_orphans_hook_tests();
    set_clear_orphans_phase_hook(None);

    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("glen", 100_000, 0).unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-cda".into()),
            "cda-1",
            "glen",
            20_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "cda-1", "glen")
            .unwrap();
    }

    let app = router(state.clone());
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain-all")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "actual_micro_usd": 0 }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["ready"], true);
    assert_eq!(v["needs_adopt_count"], 0);
    assert_eq!(v["accounts_needing_cutover"], json!([]));
    assert_eq!(state.ledger.lock().await.balance("glen").0, 100_000);
}

#[tokio::test]
async fn cutover_drain_all_abort_includes_needs_adopt() {
    let _guard = lock_clear_orphans_hook_tests();
    set_clear_orphans_phase_hook(None);

    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("hope", 120_000, 0).unwrap();
        led.credit("ivan", 120_000, 0).unwrap();
        for (id, acct) in [("cda-h", "hope"), ("cda-i", "ivan")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                25_000,
                epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(epoch, id, acct).unwrap();
        }
    }

    let gate = ownership.clone();
    set_clear_orphans_phase_hook(Some(Arc::new(move |phase| {
        if phase == "after_adopt" {
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
                .body(Body::from(json!({ "actual_micro_usd": 0 }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    set_clear_orphans_phase_hook(None);
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v = body_json(res).await;
    assert_eq!(v["action"], "cutover_drain_all_aborted");
    assert!(v.get("needs_adopt_count").is_some());
    let accounts = v["accounts_needing_cutover"].as_array().unwrap();
    assert!(!accounts.is_empty());
    assert!(state.ledger.lock().await.active_job_count() >= 1);
}
