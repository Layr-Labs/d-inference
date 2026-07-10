//! clear-orphans abort remaining ids + mixed recover/force batch race (DECISIONS #100).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{
    lock_clear_orphans_hook_tests, router, set_clear_orphans_phase_hook, Epoch,
};
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
async fn clear_orphans_abort_lists_remaining_job_ids() {
    let _guard = lock_clear_orphans_hook_tests();
    set_clear_orphans_phase_hook(None);
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch0 = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for (id, amt, hold) in [
            ("cor-res", 20_000, false),
            ("cor-held", 30_000, true),
        ] {
            led.reserve_with_epoch(
                darkbloom_coordinator::OperationKey(format!("r-{id}")),
                id,
                "pilot-account",
                amt,
                epoch0,
            )
            .unwrap();
            if hold {
                led.mark_start_authorized_fenced(epoch0, id, "pilot-account")
                    .unwrap();
            }
        }
    }
    ownership.release();
    ownership.acquire(Epoch(101)).unwrap();

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
    assert_eq!(v["action"], "clear_orphans_aborted");
    assert_eq!(v["phase"], "after_adopt");
    assert_eq!(v["active_jobs"], 2);
    assert_eq!(v["held_start_authorized"], 1);
    assert_eq!(
        v["remaining_active_job_ids"].as_array().unwrap().len(),
        2
    );
    assert_eq!(
        v["remaining_held_start_authorized_job_ids"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[tokio::test]
async fn concurrent_recover_and_force_settle_batches_on_mixed_orphans() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-mix-res".into()),
            "mix-res",
            "pilot-account",
            70_000,
            epoch,
        )
        .unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-mix-held".into()),
            "mix-held",
            "pilot-account",
            90_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "mix-held", "pilot-account")
            .unwrap();
    }

    let app = Arc::new(router(state.clone()));
    let mut recover_handles = Vec::new();
    let mut force_handles = Vec::new();

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
    for _ in 0..4 {
        let app = app.clone();
        force_handles.push(tokio::spawn(async move {
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

    let mut released = 0u64;
    for h in recover_handles {
        released += h.await.unwrap();
    }
    let mut settled = 0u64;
    for h in force_handles {
        settled += h.await.unwrap();
    }
    assert_eq!(released, 1);
    assert_eq!(settled, 1);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        1_000_000
    );
}
