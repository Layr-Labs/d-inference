//! After ownership re-acquire, adopt-job rebinds fencing so recover can clear
//! orphaned reservations (DECISIONS #66).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, Epoch};
use serde_json::json;
use tower::ServiceExt;

#[tokio::test]
async fn adopt_job_then_recover_after_epoch_reacquire() {
    let state = pilot_app_state(true);
    let epoch_at_reserve = state.ownership.epoch().0;
    assert_eq!(epoch_at_reserve, 9);

    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-adopt".into()),
            "orphan-1",
            "pilot-account",
            100_000,
            epoch_at_reserve,
        )
        .unwrap();
    }

    // Steal and re-acquire with a newer fencing epoch.
    state.ownership.release();
    state.ownership.acquire(Epoch(10)).unwrap();
    assert_eq!(state.ownership.epoch().0, 10);

    let app = router(state.clone());

    // Recover without adopt fails (ownership_lost / fencing).
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/recover-undispatched")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_id": "orphan-1" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(res).await["error"]["code"], "ownership_lost");

    // Adopt rebinds fencing to the new epoch.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/adopt-job")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_id": "orphan-1" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "adopted");
    assert_eq!(v["previous_fencing_epoch"], 9);
    assert_eq!(v["fencing_epoch"], 10);

    // Recover now succeeds and refunds.
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/recover-undispatched")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_id": "orphan-1" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "released");
    assert_eq!(v["balance_micro_usd"], 1_000_000);
    assert_eq!(v["active_jobs"], 0);
}
