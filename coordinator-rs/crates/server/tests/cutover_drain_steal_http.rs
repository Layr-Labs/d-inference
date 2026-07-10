//! cutover-drain aborts without outbox drain on mid-flight steal (DECISIONS #92).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, set_clear_orphans_phase_hook, Epoch};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

static HOOK_TEST_LOCK: Mutex<()> = Mutex::new(());

#[tokio::test]
async fn cutover_drain_aborts_without_draining_on_steal() {
    let _guard = HOOK_TEST_LOCK.lock().unwrap();
    let state = pilot_app_state(true);
    let ownership = state.ownership.clone();
    let epoch0 = ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-cds".into()),
            "cds-res",
            "pilot-account",
            15_000,
            epoch0,
        )
        .unwrap();
    }
    ownership.release();
    ownership.acquire(Epoch(61)).unwrap();

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
                .uri("/v1/admin/cutover-drain")
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
    // Outbox must not have been drained — job still active, no settle/release outbox.
    assert_eq!(state.ledger.lock().await.active_job_count(), 1);
    assert_eq!(state.outbox.lock().await.len(), 0);
}
