//! Batch abort partial progress + resume via cutover-drain (DECISIONS #97).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{lock_admin_batch_hook_tests, router, set_admin_batch_job_hook, Epoch};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
async fn force_settle_batch_abort_reports_partial_then_cutover_resumes() {
    let _guard = lock_admin_batch_hook_tests();
    set_admin_batch_job_hook(None);
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for id in ["pfs-a", "pfs-b"] {
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
    let v = body_json(res).await;
    assert_eq!(v["error"]["code"], "ownership_lost");
    assert_eq!(v["action"], "force_settle_batch_aborted");
    assert_eq!(v["settled_count"], 1);
    assert_eq!(v["charged_micro_usd"], 0);
    assert_eq!(v["active_jobs"], 1);
    assert_eq!(v["held_start_authorized"], 1);
    assert_eq!(state.ledger.lock().await.active_job_count(), 1);

    ownership.acquire(Epoch(epoch + 10)).unwrap();
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
    assert_eq!(v["ready"], true);
    assert_eq!(v["clear_orphans"]["settled_count"], 1);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        1_000_000
    );
}

#[tokio::test]
async fn recover_batch_abort_reports_partial_then_cutover_resumes() {
    let _guard = lock_admin_batch_hook_tests();
    set_admin_batch_job_hook(None);
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for id in ["prb-a", "prb-b"] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                "pilot-account",
                40_000,
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
    let v = body_json(res).await;
    assert_eq!(v["action"], "recover_undispatched_batch_aborted");
    assert_eq!(v["released_count"], 1);
    assert_eq!(v["refunded_micro_usd"], 40_000);
    assert_eq!(state.ledger.lock().await.active_job_count(), 1);

    ownership.acquire(Epoch(epoch + 11)).unwrap();
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
    assert_eq!(body_json(res).await["ready"], true);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        1_000_000
    );
}
