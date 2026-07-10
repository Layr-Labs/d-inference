//! Concurrent HTTP deposit vs force-settle: money conserved.

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
async fn concurrent_http_deposit_vs_force_settle_conserves() {
    let state = test_state();
    let ledger = state.ledger.clone();
    {
        let mut led = ledger.lock().await;
        led.reserve(
            darkbloom_coordinator::OperationKey("r-dfs".into()),
            "held-dfs",
            "pilot-account",
            200_000,
        )
        .unwrap();
        led.mark_start_authorized("held-dfs", "pilot-account")
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
                            "event_id": "evt_dfs",
                            "amount_micro_usd": 75_000,
                            "withdrawable_micro_usd": 25_000
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

    let app_f = app.clone();
    let force = tokio::spawn(async move {
        let res = app_f
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/admin/force-settle")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        json!({
                            "job_id": "held-dfs",
                            "actual_micro_usd": 60_000,
                            "terminal_digest": "dfs-d"
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        body_json(res).await["action"].as_str().unwrap() == "released"
    });

    assert!(deposit.await.unwrap());
    assert!(force.await.unwrap());

    let led = ledger.lock().await;
    assert_eq!(led.active_job_count(), 0);
    // Seed 1M + deposit 75k - charge 60k = 1_015_000
    assert_eq!(led.balance("pilot-account").0, 1_015_000);
    assert_eq!(led.job_disposition("held-dfs"), Some("force_settled"));
}
