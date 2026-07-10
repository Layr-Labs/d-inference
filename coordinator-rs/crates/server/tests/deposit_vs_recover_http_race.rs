//! Concurrent HTTP deposit vs recover-undispatched: money conserved.

mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{body_json, pilot_app_state};
use darkbloom_coordinator::router;
use serde_json::json;
use tower::ServiceExt;

fn test_state() -> darkbloom_coordinator::AppState {
    pilot_app_state(true)
}

#[tokio::test]
async fn concurrent_http_deposit_vs_recover_undispatched_conserves() {
    let state = test_state();
    let ledger = state.ledger.clone();
    {
        let mut led = ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-dru".into()),
            "undisp-dru",
            "pilot-account",
            150_000,
        )
        .unwrap();
    }
    let app = router(state);

    let app_d = app.clone();
    let deposit = tokio::spawn(async move {
        let res = app_d
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/admin/deposits")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        json!({
                            "event_id": "evt_dru",
                            "amount_micro_usd": 50_000,
                            "withdrawable_micro_usd": 10_000
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        body_json(res).await["applied"].as_bool().unwrap()
    });

    let app_r = app.clone();
    let recover = tokio::spawn(async move {
        let res = app_r
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/admin/recover-undispatched")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        json!({ "job_id": "undisp-dru" }).to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        body_json(res).await["action"].as_str().unwrap() == "released"
    });

    assert!(deposit.await.unwrap());
    assert!(recover.await.unwrap());

    let led = ledger.lock().await;
    assert_eq!(led.active_job_count(), 0);
    // Seed 1M + deposit 50k, full reservation refunded → 1_050_000
    assert_eq!(led.balance("pilot-account").0, 1_050_000);
}
