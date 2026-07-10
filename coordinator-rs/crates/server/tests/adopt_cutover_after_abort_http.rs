//! Concurrent adopt-jobs with cutover-drain after steal (DECISIONS #101).

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
async fn adopt_jobs_then_cutover_drain_after_clear_abort() {
    let _guard = lock_clear_orphans_hook_tests();
    set_clear_orphans_phase_hook(None);
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch0 = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        for (id, amt, hold) in [
            ("ajc-res", 25_000, false),
            ("ajc-held", 35_000, true),
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
    ownership.acquire(Epoch(110)).unwrap();

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
    let abort = body_json(res).await;
    assert_eq!(abort["remaining_active_job_ids"].as_array().unwrap().len(), 2);

    // Quiescence without ownership still lists orphans.
    let res = app
        .clone()
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
    assert_eq!(q["ownership_holding"], false);
    assert_eq!(q["active_jobs"], 2);
    assert_eq!(q["cutover_hint"], "cutover-drain");

    ownership.acquire(Epoch(111)).unwrap();

    let app = Arc::new(app);
    let mut adopt_handles = Vec::new();
    let mut drain_handles = Vec::new();
    for _ in 0..4 {
        let app = app.clone();
        adopt_handles.push(tokio::spawn(async move {
            let res = app
                .as_ref()
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
            assert_eq!(res.status(), StatusCode::OK);
            body_json(res).await["adopted_count"].as_u64().unwrap_or(0)
        }));
    }
    for _ in 0..4 {
        let app = app.clone();
        drain_handles.push(tokio::spawn(async move {
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
            body_json(res).await["ready"].as_bool().unwrap_or(false)
        }));
    }

    for h in adopt_handles {
        let _ = h.await.unwrap();
    }
    let mut ready_seen = false;
    for h in drain_handles {
        if h.await.unwrap() {
            ready_seen = true;
        }
    }
    assert!(ready_seen);
    assert_eq!(state.ledger.lock().await.active_job_count(), 0);
    assert_eq!(
        state.ledger.lock().await.balance("pilot-account").0,
        1_000_000
    );
    assert_eq!(state.outbox.lock().await.pending_under_retry_cap(), 0);
}
