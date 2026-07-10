//! Quiescence active_jobs_detail includes fencing/funded_start (DECISIONS #76).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use tower::ServiceExt;

#[tokio::test]
async fn quiescence_active_jobs_detail_reports_fencing_and_funded() {
    let state = pilot_app_state(true);
    let epoch = state.ownership.epoch().0;
    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-detail-a".into()),
            "detail-a",
            "pilot-account",
            80_000,
            epoch,
        )
        .unwrap();
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-detail-b".into()),
            "detail-b",
            "pilot-account",
            120_000,
            epoch,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch, "detail-b", "pilot-account")
            .unwrap();
    }
    // Steal — detail still visible without ownership.
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
    assert_eq!(v["active_jobs"], 2);
    assert_eq!(v["active_jobs_detail"].as_array().unwrap().len(), 2);
    assert_eq!(v["active_jobs_detail"][0]["job_id"], "detail-a");
    assert_eq!(v["active_jobs_detail"][0]["funded_start"], false);
    assert_eq!(v["active_jobs_detail"][0]["fencing_epoch"], epoch);
    assert_eq!(v["active_jobs_detail"][0]["reserved_micro_usd"], 80_000);
    assert_eq!(v["active_jobs_detail"][1]["job_id"], "detail-b");
    assert_eq!(v["active_jobs_detail"][1]["funded_start"], true);
    assert_eq!(v["active_jobs_detail"][1]["reserved_micro_usd"], 120_000);
    assert_eq!(v["held_start_authorized"], 1);
}
