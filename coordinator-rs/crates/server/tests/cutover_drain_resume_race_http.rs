//! Resume after cutover-drain steal + concurrent cutover-drain (DECISIONS #93).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{lock_clear_orphans_hook_tests, router, set_clear_orphans_phase_hook, Epoch};
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
async fn resume_cutover_drain_after_midflight_steal() {
    let _guard = lock_clear_orphans_hook_tests();
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch0 = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for (id, amt, hold) in [
            ("rcd-res", 22_000, false),
            ("rcd-held", 33_000, true),
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
                .uri("/v1/admin/cutover-drain")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    set_clear_orphans_phase_hook(None);
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(res).await["action"], "clear_orphans_aborted");
    assert_eq!(state.ledger.lock().await.active_job_count(), 2);

    // Re-acquire and finish with cutover-drain.
    ownership.acquire(Epoch(71)).unwrap();
    let res = app
        .clone()
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
    assert_eq!(v["action"], "cutover_drained");
    assert_eq!(v["ready"], true);
    assert_eq!(v["clear_orphans"]["released_count"], 1);
    assert_eq!(v["clear_orphans"]["settled_count"], 1);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        1_000_000
    );

    let res = app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/v1/admin/quiescence")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(body_json(res).await["cutover_hint"], "ready");
}

#[tokio::test]
async fn concurrent_cutover_drain_conserves_money_and_is_idempotent() {
    // Hold hook lock so a parallel steal-hook test cannot fire into this clear path.
    let _guard = lock_clear_orphans_hook_tests();
    set_clear_orphans_phase_hook(None);
    let state = pilot_app_state(true);
    let epoch0 = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-ccd".into()),
            "ccd-res",
            "pilot-account",
            40_000,
            epoch0,
        )
        .unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-ccd-h".into()),
            "ccd-held",
            "pilot-account",
            60_000,
            epoch0,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch0, "ccd-held", "pilot-account")
            .unwrap();
    }
    state.ownership.release();
    state.ownership.acquire(Epoch(72)).unwrap();

    let app = Arc::new(router(state.clone()));
    let mut handles = Vec::new();
    for _ in 0..8 {
        let app = app.clone();
        handles.push(tokio::spawn(async move {
            let res = app
                .as_ref()
                .clone()
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
            body_json(res).await
        }));
    }
    let mut released = 0usize;
    let mut settled = 0usize;
    let mut ready_count = 0usize;
    for h in handles {
        let v = h.await.unwrap();
        released += v["clear_orphans"]["released_count"]
            .as_u64()
            .unwrap_or(0) as usize;
        settled += v["clear_orphans"]["settled_count"]
            .as_u64()
            .unwrap_or(0) as usize;
        if v["ready"].as_bool().unwrap_or(false) {
            ready_count += 1;
        }
    }
    assert_eq!(released, 1);
    assert_eq!(settled, 1);
    assert!(ready_count >= 1);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        1_000_000
    );
    assert_eq!(state.outbox.lock().await.pending_under_retry_cap(), 0);
}
