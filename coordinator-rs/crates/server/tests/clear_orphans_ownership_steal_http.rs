//! Mid-flight ownership loss aborts clear-orphans money moves (DECISIONS #85).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, set_clear_orphans_phase_hook, Epoch};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

/// Phase hook is process-global — serialize tests that install it.
static HOOK_TEST_LOCK: Mutex<()> = Mutex::new(());

#[tokio::test]
async fn clear_orphans_aborts_after_adopt_on_ownership_steal() {
    let _guard = HOOK_TEST_LOCK.lock().unwrap();
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch0 = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-steal-res".into()),
            "steal-res",
            "pilot-account",
            40_000,
            epoch0,
        )
        .unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-steal-held".into()),
            "steal-held",
            "pilot-account",
            50_000,
            epoch0,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch0, "steal-held", "pilot-account")
            .unwrap();
    }
    // Rebind to a fresh epoch so adopt has work to do, then steal after adopt.
    ownership.release();
    ownership.acquire(Epoch(77)).unwrap();

    let gate = ownership.clone();
    set_clear_orphans_phase_hook(Some(Arc::new(move |phase| {
        if phase == "after_adopt" {
            gate.release();
        }
    })));

    let app = router(state.clone());
    let res = app
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
    assert_eq!(v["error"]["code"], "ownership_lost");
    assert_eq!(v["action"], "clear_orphans_aborted");
    assert_eq!(v["phase"], "after_adopt");
    assert_eq!(v["adopted_count"], 2);
    assert_eq!(v["released_count"], 0);
    assert_eq!(v["settled_count"], 0);
    // Money must not have moved — both jobs still active.
    assert_eq!(state.ledger.lock().await.active_job_count(), 2);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        1_000_000 - 90_000
    );
}

#[tokio::test]
async fn clear_orphans_aborts_after_recover_before_force_settle() {
    let _guard = HOOK_TEST_LOCK.lock().unwrap();
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch0 = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-ar".into()),
            "ar-res",
            "pilot-account",
            30_000,
            epoch0,
        )
        .unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-ah".into()),
            "ar-held",
            "pilot-account",
            70_000,
            epoch0,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch0, "ar-held", "pilot-account")
            .unwrap();
    }
    ownership.release();
    ownership.acquire(Epoch(88)).unwrap();

    let gate = ownership.clone();
    set_clear_orphans_phase_hook(Some(Arc::new(move |phase| {
        if phase == "after_recover" {
            gate.release();
        }
    })));

    let app = router(state.clone());
    let res = app
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
    assert_eq!(v["phase"], "after_recover");
    assert_eq!(v["released_count"], 1);
    assert_eq!(v["settled_count"], 0);
    // Reserved refunded; held still active.
    assert_eq!(state.ledger.lock().await.active_job_count(), 1);
    assert_eq!(state.ledger.lock().await.held_start_authorized_count(), 1);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        1_000_000 - 70_000
    );
}
