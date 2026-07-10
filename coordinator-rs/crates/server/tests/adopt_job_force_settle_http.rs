//! After ownership re-acquire, adopt-job then force-settle clears a held
//! start_authorized orphan (DECISIONS #66).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::{router, Epoch};
use serde_json::json;
use tower::ServiceExt;

#[tokio::test]
async fn adopt_job_then_force_settle_after_epoch_reacquire() {
    let state = pilot_app_state(true);
    let epoch_at_reserve = state.ownership.epoch().0;
    assert_eq!(epoch_at_reserve, 9);

    {
        let mut led = state.ledger.lock().await;
        led.reserve_with_epoch(
            darkbloom_coordinator::OperationKey("r-adopt-fs".into()),
            "orphan-held",
            "pilot-account",
            200_000,
            epoch_at_reserve,
        )
        .unwrap();
        led.mark_start_authorized_fenced(epoch_at_reserve, "orphan-held", "pilot-account")
            .unwrap();
    }

    state.ownership.release();
    state.ownership.acquire(Epoch(11)).unwrap();
    assert_eq!(state.ownership.epoch().0, 11);

    let app = router(state.clone());

    // Force-settle without adopt fails.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "orphan-held",
                        "actual_micro_usd": 40_000,
                        "terminal_digest": "adopt-fs-d"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(res).await["error"]["code"], "ownership_lost");

    // Adopt rebinds fencing.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/adopt-job")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_id": "orphan-held" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(body_json(res).await["fencing_epoch"], 11);

    // Force-settle now clears the hold.
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/force-settle")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({
                        "job_id": "orphan-held",
                        "actual_micro_usd": 40_000,
                        "terminal_digest": "adopt-fs-d"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let v = body_json(res).await;
    assert_eq!(v["action"], "released");
    assert_eq!(v["held_start_authorized"], 0);
    // 1M - 200k + 160k refund = 960k
    assert_eq!(v["balance_micro_usd"], 960_000);
}
