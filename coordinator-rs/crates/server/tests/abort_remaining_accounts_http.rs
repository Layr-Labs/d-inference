//! Abort responses include accounts_needing_cutover (DECISIONS #125).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{
    lock_admin_batch_hook_tests, lock_clear_orphans_hook_tests, router, set_admin_batch_job_hook,
    set_clear_orphans_phase_hook, Epoch,
};
use serde_json::json;
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};
use tower::ServiceExt;

#[tokio::test]
async fn clear_orphans_abort_lists_remaining_accounts() {
    let _guard = lock_clear_orphans_hook_tests();
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch0 = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("iris", 200_000, 0).unwrap();
        led.credit("jade", 200_000, 0).unwrap();
        for (id, acct, hold) in [
            ("ab-i1", "iris", true),
            ("ab-j1", "jade", false),
            ("ab-j2", "jade", true),
        ] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                30_000,
                epoch0,
            )
            .unwrap();
            if hold {
                led.mark_start_authorized_fenced(epoch0, id, acct).unwrap();
            }
        }
    }
    ownership.release();
    ownership.acquire(Epoch(70)).unwrap();

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
                .uri("/v1/admin/clear-orphans")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    set_clear_orphans_phase_hook(None);
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v = body_json(res).await;
    assert_eq!(v["action"], "clear_orphans_aborted");
    assert_eq!(v["phase"], "after_adopt");
    assert_eq!(v["needs_adopt_count"], 0); // adopted before abort
    let mut accounts = v["accounts_needing_cutover"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    accounts.sort();
    assert_eq!(accounts, vec!["iris".to_string(), "jade".to_string()]);
    assert_eq!(v["active_jobs"], 3);

    // Resume via cutover-drain-all using abort's account list (no quiescence).
    ownership.acquire(Epoch(71)).unwrap();
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/cutover-drain-all")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "actual_micro_usd": 0,
                        "accounts": accounts,
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["ready"], true);
    assert_eq!(state.ledger.lock().await.balance("iris").0, 200_000);
    assert_eq!(state.ledger.lock().await.balance("jade").0, 200_000);
}

#[tokio::test]
async fn force_settle_batch_abort_lists_remaining_accounts() {
    let _guard = lock_admin_batch_hook_tests();
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("kate", 180_000, 0).unwrap();
        led.credit("liam", 180_000, 0).unwrap();
        for (id, acct) in [("ab-k1", "kate"), ("ab-k2", "kate"), ("ab-l1", "liam")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                40_000,
                epoch,
            )
            .unwrap();
            led.mark_start_authorized_fenced(epoch, id, acct).unwrap();
        }
    }

    let seen = Arc::new(AtomicUsize::new(0));
    let gate = ownership.clone();
    let seen_h = seen.clone();
    set_admin_batch_job_hook(Some(Arc::new(move |_job| {
        if seen_h.fetch_add(1, Ordering::SeqCst) == 1 {
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
                .body(Body::from(json!({ "actual_micro_usd": 0 }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    set_admin_batch_job_hook(None);
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v = body_json(res).await;
    assert_eq!(v["action"], "force_settle_batch_aborted");
    assert_eq!(v["settled_count"], 1);
    assert!(v["accounts_needing_cutover"].as_array().unwrap().len() >= 1);
    assert!(v.get("needs_adopt_count").is_some());
    // One settled; two held remain across kate/liam.
    assert_eq!(v["held_start_authorized"], 2);

    ownership.acquire(Epoch(epoch + 3)).unwrap();
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
    assert_eq!(body_json(res).await["ready"], true);
    assert_eq!(state.ledger.lock().await.balance("kate").0, 180_000);
    assert_eq!(state.ledger.lock().await.balance("liam").0, 180_000);
}

#[tokio::test]
async fn recover_batch_abort_lists_remaining_accounts() {
    let _guard = lock_admin_batch_hook_tests();
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.credit("mira", 150_000, 0).unwrap();
        led.credit("noah", 150_000, 0).unwrap();
        for (id, acct) in [("ab-m1", "mira"), ("ab-m2", "mira"), ("ab-n1", "noah")] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                acct,
                25_000,
                epoch,
            )
            .unwrap();
        }
    }

    let seen = Arc::new(AtomicUsize::new(0));
    let gate = ownership.clone();
    let seen_h = seen.clone();
    set_admin_batch_job_hook(Some(Arc::new(move |_job| {
        if seen_h.fetch_add(1, Ordering::SeqCst) == 1 {
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
    let v = body_json(res).await;
    assert_eq!(v["action"], "recover_undispatched_batch_aborted");
    assert_eq!(v["released_count"], 1);
    let mut accounts = v["accounts_needing_cutover"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    accounts.sort();
    assert!(accounts.contains(&"mira".to_string()) || accounts.contains(&"noah".to_string()));
    assert!(v.get("needs_adopt_count").is_some());
}
