//! After ownership loss, recover must not release reserved funds (DECISIONS #47).

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use serde_json::json;
use tower::ServiceExt;

#[tokio::test]
async fn recover_after_ownership_loss_leaves_reservation() {
    let state = pilot_app_state(true);
    {
        let mut led = state.ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-own".into()),
            "undisp-own",
            "pilot-account",
            90_000,
        )
        .unwrap();
    }
    // Steal fencing mid-flight.
    state.ownership.release();
    assert!(state.ownership.assert_holding().is_err());

    let app = router(state.clone());
    let res = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/admin/recover-undispatched")
                .header("content-type", "application/json")
                .body(Body::from(json!({ "job_id": "undisp-own" }).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body_json(res).await["error"]["code"], "ownership_lost");

    let led = state.ledger.lock().await;
    assert_eq!(led.active_job_count(), 1);
    assert_eq!(led.job_reserved_total("undisp-own").map(|m| m.0), Some(90_000));
    assert_eq!(led.balance("pilot-account").0, 910_000);
}
