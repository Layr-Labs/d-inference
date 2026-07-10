//! After ownership steal, quiescence (without holding) still lists active_job_ids
//! for orphan discovery (DECISIONS #30/#71/#72).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use tower::ServiceExt;

#[tokio::test]
async fn quiescence_without_ownership_lists_active_job_ids() {
    let state = pilot_app_state(true);
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-q-orphan".into()),
            "orphan-q",
            "pilot-account",
            100_000,
            state.ownership.epoch().0,
        )
        .unwrap();
    }
    // Steal — cutover ops still need to see orphans.
    state.ownership.release();

    let app = router(state);
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
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let v = body_json(res).await;
    assert_eq!(v["ownership_holding"], false);
    assert_eq!(v["ready"], false);
    assert_eq!(v["active_jobs"], 1);
    assert_eq!(v["active_job_ids"][0], "orphan-q");
    assert_eq!(v["held_start_authorized"], 0);
}
