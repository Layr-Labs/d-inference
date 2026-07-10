//! After mid-flight clear-orphans abort, re-acquire + clear + drain resumes (DECISIONS #87).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{lock_clear_orphans_hook_tests, router, set_clear_orphans_phase_hook, Epoch};
use std::sync::Arc;
use tower::ServiceExt;

#[tokio::test]
async fn resume_clear_orphans_after_midflight_abort() {
    let _guard = lock_clear_orphans_hook_tests();
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch0 = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for (id, amt, hold) in [
            ("resume-res", 20_000, false),
            ("resume-held", 35_000, true),
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
    ownership.acquire(Epoch(55)).unwrap();

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
    assert_eq!(body_json(res).await["phase"], "after_adopt");
    assert_eq!(state.ledger.lock().await.active_job_count(), 2);

    // Re-acquire and finish cutover.
    ownership.acquire(Epoch(56)).unwrap();
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
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["released_count"], 1);
    assert_eq!(v["settled_count"], 1);
    assert_eq!(v["active_jobs"], 0);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        1_000_000
    );

    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/outbox-drain")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(body_json(res).await["ready"], true);

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
    let q = body_json(res).await;
    assert_eq!(q["ready"], true);
    assert_eq!(q["cutover_hint"], "ready");
}
