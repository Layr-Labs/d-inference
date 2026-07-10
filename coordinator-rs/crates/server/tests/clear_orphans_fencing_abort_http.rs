//! clear-orphans / batch abort on ledger OwnershipLost (DECISIONS #119).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{
    lock_admin_batch_hook_tests, lock_clear_orphans_hook_tests, router, set_admin_batch_job_hook,
    set_clear_orphans_phase_hook, Epoch,
};
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
async fn clear_orphans_aborts_on_fencing_mismatch_after_reacquire() {
    let _guard = lock_clear_orphans_hook_tests();
    set_clear_orphans_phase_hook(None);
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-fm1".into()),
            "fm-held",
            "pilot-account",
            50_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "fm-held", "pilot-account")
            .unwrap();
    }

    // After adopt+recover phases, steal and re-acquire with a new epoch without
    // re-adopting — force_settle then hits OwnershipLost (DECISIONS #119).
    let gate = ownership.clone();
    let old = epoch;
    set_clear_orphans_phase_hook(Some(Arc::new(move |phase| {
        if phase == "after_recover" {
            gate.release();
            gate.acquire(Epoch(old + 50)).unwrap();
        }
    })));

    let app = router(state.clone());
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/clear-orphans")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"actual_micro_usd":0}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    set_clear_orphans_phase_hook(None);
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v = body_json(res).await;
    assert_eq!(v["action"], "clear_orphans_aborted");
    assert_eq!(v["phase"], "during_force_settle");
    assert_eq!(v["error"]["code"], "ownership_lost");
    // Hold remains — money not silently skipped.
    assert_eq!(state.ledger.lock().await.held_start_authorized_count(), 1);
    assert_eq!(state.ledger.lock().await.balance("pilot-account").0, 950_000);
}

#[tokio::test]
async fn force_settle_batch_aborts_on_fencing_ownership_lost() {
    let _guard = lock_admin_batch_hook_tests();
    set_admin_batch_job_hook(None);
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for id in ["fb-a", "fb-b"] {
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
    // Leave jobs at old epoch; re-acquire with new epoch without adopt.
    ownership.release();
    ownership.acquire(Epoch(epoch + 7)).unwrap();

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
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v = body_json(res).await;
    assert_eq!(v["action"], "force_settle_batch_aborted");
    assert_eq!(v["error"]["code"], "ownership_lost");
    assert_eq!(v["settled_count"], 0);
    assert_eq!(state.ledger.lock().await.held_start_authorized_count(), 2);
    assert_eq!(state.ledger.lock().await.balance("pilot-account").0, 920_000);
}

#[tokio::test]
async fn recover_batch_aborts_on_fencing_ownership_lost() {
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for id in ["rb-a", "rb-b"] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                "pilot-account",
                30_000,
                epoch,
            )
            .unwrap();
        }
    }
    ownership.release();
    ownership.acquire(Epoch(epoch + 9)).unwrap();

    let app = router(state.clone());
    let res = app
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
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v = body_json(res).await;
    assert_eq!(v["action"], "recover_undispatched_batch_aborted");
    assert_eq!(v["released_count"], 0);
    assert_eq!(state.ledger.lock().await.active_job_count(), 2);
    assert_eq!(state.ledger.lock().await.balance("pilot-account").0, 940_000);
}
